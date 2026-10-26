import Foundation

/// Conservative whole-function scalar admission. Every edge has an exact
/// in-function target. A single natural loop may carry register phis; all
/// other effects remain on the legacy route.
struct ScalarCFGStatePlan {
    struct PhiDraft {
        let blockIndex: Int
        let registerIndex: Int
        let destination: MacIRValue
        /// x-registers by default; the region path also joins v-registers.
        var registerName: String? = nil
        var bitWidth = 64
        var register: String { registerName ?? "x\(registerIndex)" }
    }
    struct ConditionalFork {
        let register: String
        let condition: String
        let taken: Int
        let fallthroughBlock: Int
    }

    let cfg: CFG
    let blockAtStart: [Int: Int]
    let blockAtEnd: [Int: Int]
    let conditionalForks: [Int: ConditionalFork]
    let referencedXRegisters: [Int]
    /// Vector registers joined at CFG merges (region path only). Every other
    /// vector register that predecessors disagree on becomes unavailable.
    var referencedVRegisters: [Int] = []
    /// Loop headers whose natural loop writes SP. Only these, and joins whose
    /// completed predecessors disagree on SP, need an SP join; elsewhere SP
    /// (and with it the stack coordinate system) is carried unchanged.
    var spWritingLoopHeaders: Set<Int> = []
    var referencesSP = false
    /// Recovery crosses only pending blocks with no SP write. The region
    /// admission scan separately certifies every SP writer as modeled arithmetic.
    var spWritingBlocks: Set<Int> = []
    var permitsPendingSPRecovery = false

    private func pendingStackPointerVersion(
        entering blockIndex: Int, outgoing: [Int: BuilderState]
    ) -> Int? {
        guard permitsPendingSPRecovery else { return nil }
        var active: Set<Int> = [blockIndex]
        var memo: [Int: Int] = [:]
        func visit(_ index: Int) -> Int? {
            if let version = memo[index] { return version }
            if let state = outgoing[index] {
                guard case let .register(name, version) = state.readRegister("sp"),
                      name == "sp" else { return nil }
                memo[index] = version
                return version
            }
            guard !spWritingBlocks.contains(index), active.insert(index).inserted else { return nil }
            defer { active.remove(index) }
            let predecessors = cfg.blocks[index].predecessors
            guard !predecessors.isEmpty else { return nil }
            var agreed: Int?
            for predecessor in predecessors {
                guard let version = visit(predecessor),
                      agreed == nil || agreed == version else { return nil }
                agreed = version
            }
            if let agreed { memo[index] = agreed }
            return agreed
        }
        var agreed: Int?
        for predecessor in cfg.blocks[blockIndex].predecessors {
            guard let version = visit(predecessor),
                  agreed == nil || agreed == version else { return nil }
            agreed = version
        }
        return agreed
    }

    /// Natural-loop headers (back-edge targets) whose loop contains a block
    /// listed in `writers`.
    static func loopHeaders(in cfg: CFG, containingAnyOf writers: Set<Int>) -> Set<Int> {
        var headers: Set<Int> = []
        for edge in cfg.backEdges {
            var loop: Set<Int> = [edge.to, edge.from]
            var work = [edge.from]
            while let block = work.popLast() {
                if block == edge.to { continue }
                for predecessor in cfg.blocks[block].predecessors where !loop.contains(predecessor) {
                    loop.insert(predecessor); work.append(predecessor)
                }
            }
            if !loop.isDisjoint(with: writers) { headers.insert(edge.to) }
        }
        return headers
    }

    static func admit<Row: DecompilerInstructionRow>(_ rows: [Row],
                                                       hasExternalFacts: Bool,
                                                       allowVectorLoop: Bool = false) -> Self? {
        guard !hasExternalFacts, rows.count >= 4, rows.count <= 64,
              rows.last?.mnemonic.lowercased() == "ret" else { return nil }
        var hasBranch = false
        var hasLoopArithmetic = false
        var vectorLoads = 0, vectorStores = 0, vectorTransforms = 0
        var targets: [UInt64] = []
        var referencedXRegisters: Set<Int> = []
        var control: [MacIRInstruction] = []
        control.reserveCapacity(rows.count)
        for (index, row) in rows.enumerated() {
            if index > 0 {
                let next = rows[index - 1].address.addingReportingOverflow(4)
                guard !next.overflow, next.partialValue == row.address else { return nil }
            }
            let mnemonic = row.mnemonic.lowercased()
            let operands = row.operands.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            for operand in operands {
                if let index = xRegisterIndex(operand) { referencedXRegisters.insert(index) }
            }
            let operation: MacIROperation
            switch mnemonic {
            case "mov":
                guard operands.count == 2, isGPR(operands[0]),
                      isGPR(operands[1]) || immediate(operands[1]) != nil else { return nil }
                operation = .unknown(destination: nil, mnemonic: mnemonic, operands: row.operands)
            case "nop":
                guard operands.isEmpty else { return nil }
                operation = .unknown(destination: nil, mnemonic: mnemonic, operands: row.operands)
            case "ldr", "str":
                guard allowVectorLoop,
                      let transfer = MacIRBuilder.neonBufferSequence(row),
                      transfer.mode == .postIndex, transfer.delta == 16,
                      transfer.vectors.count == 1 else { return nil }
                if let index = xRegisterIndex(transfer.base) { referencedXRegisters.insert(index) }
                if transfer.effect == .load { vectorLoads += 1 } else { vectorStores += 1 }
                operation = .unknown(destination: nil, mnemonic: mnemonic, operands: row.operands)
            case "eor":
                guard allowVectorLoop,
                      let logical = MacIRBuilder.neonLogical(mnemonic: mnemonic, operandText: row.operands),
                      logical.kind == .eor, logical.width == .bytes16 else { return nil }
                vectorTransforms += 1
                operation = .unknown(destination: nil, mnemonic: mnemonic, operands: row.operands)
            case "add", "subs":
                guard operands.count == 3, operands[0] == operands[1],
                      xRegisterIndex(operands[0]) != nil,
                      (xRegisterIndex(operands[2]) != nil || immediate(operands[2]) != nil) else { return nil }
                hasLoopArithmetic = true
                operation = .unknown(destination: nil, mnemonic: mnemonic, operands: row.operands)
            case "cbz", "cbnz":
                guard operands.count == 2, isGPR(operands[0]),
                      let target = address(operands[1]), target <= UInt64(Int64.max) else { return nil }
                hasBranch = true
                targets.append(target)
                operation = .conditionalBranch(condition: mnemonic == "cbz" ? "==" : "!=",
                                               left: .immediate(0), right: .immediate(0),
                                               target: .immediate(Int64(bitPattern: target)))
            case "b.ne":
                guard operands.count == 1,
                      let target = address(operands[0]), target <= UInt64(Int64.max),
                      index > 0, rows[index - 1].mnemonic.lowercased() == "subs" else { return nil }
                hasBranch = true
                targets.append(target)
                operation = .conditionalBranch(condition: "!=", left: .immediate(0),
                                               right: .immediate(0),
                                               target: .immediate(Int64(bitPattern: target)))
            case "b":
                guard operands.count == 1, let target = address(operands[0]),
                      target <= UInt64(Int64.max) else { return nil }
                hasBranch = true
                targets.append(target)
                operation = .intrinsic(destination: nil, name: "branch",
                                       arguments: [.immediate(Int64(bitPattern: target))])
            case "ret":
                guard index == rows.count - 1, operands.isEmpty else { return nil }
                operation = .returnValue(nil)
            default:
                return nil
            }
            control.append(MacIRInstruction(
                source: MacIRSourceSpan(address: row.address, byteText: row.bytes,
                                        mnemonic: mnemonic, operands: row.operands,
                                        comment: row.comment), operation: operation))
        }
        let rowAddresses = Set(rows.map(\.address))
        guard hasBranch, targets.allSatisfy(rowAddresses.contains) else { return nil }
        let cfg = CFGBuilder.buildCFG(instructions: control)
        guard !cfg.hasUnresolvedTargets, cfg.irreducibleBlocks.isEmpty,
              cfg.backEdges.count <= 1,
              cfg.backEdges.allSatisfy({ $0.to != cfg.entryIndex }),
              cfg.blocks.allSatisfy({ block in
                  block.successors.allSatisfy {
                      $0 > block.index || cfg.backEdges.contains(CFGEdge(block.index, $0))
                  }
              }),
              !hasLoopArithmetic || cfg.backEdges.count == 1,
              cfg.backEdges.isEmpty || rows.contains(where: { $0.mnemonic.lowercased() == "b.ne" }) else { return nil }
        if allowVectorLoop {
            let vectorOrder = rows.enumerated().compactMap { index, row -> (Int, String)? in
                let mnemonic = row.mnemonic.lowercased()
                return ["ldr", "str", "eor"].contains(mnemonic) ? (index, mnemonic) : nil
            }
            guard vectorLoads == 2, vectorStores == 1, vectorTransforms == 1,
                  cfg.backEdges.count == 1,
                  rows.filter({ $0.mnemonic.lowercased() == "cbz" }).count == 1,
                  rows.filter({ $0.mnemonic.lowercased() == "b.ne" }).count == 1,
                  cfg.blocks.count == 3, cfg.entryIndex == 0,
                  cfg.blocks[0].endIndex == 1,
                  cfg.blocks[1].startIndex == 1,
                  cfg.blocks[1].endIndex == rows.count - 1,
                  cfg.blocks[2].startIndex == rows.count - 1,
                  cfg.backEdges == [CFGEdge(1, 1)],
                  Set(cfg.blocks[0].successors) == [1, 2],
                  Set(cfg.blocks[1].successors) == [1, 2],
                  rows[0].mnemonic.lowercased() == "cbz",
                  rows[rows.count - 2].mnemonic.lowercased() == "b.ne",
                  vectorOrder.map({ $0.1 }) == ["ldr", "ldr", "eor", "str"],
                  vectorOrder.allSatisfy({ cfg.blocks[1].instructionRange.contains($0.0) }) else { return nil }
        }
        // `subs` must dominate its flag-consuming b.ne within one basic block.
        // A direct target at b.ne would bypass the textual predecessor and
        // make the recovered branch condition unavailable on that edge.
        for (index, row) in rows.enumerated() where row.mnemonic.lowercased() == "b.ne" {
            guard let block = cfg.blocks.first(where: { $0.instructionRange.contains(index) }),
                  block.startIndex < index,
                  rows[index - 1].mnemonic.lowercased() == "subs" else { return nil }
        }
        var reachable: Set<Int> = [cfg.entryIndex]
        for _ in 0..<cfg.blocks.count {
            for block in cfg.blocks where reachable.contains(block.index) {
                reachable.formUnion(block.successors)
            }
        }
        guard reachable.count == cfg.blocks.count,
              cfg.blocks.last?.endIndex == rows.count,
              cfg.blocks.last?.predecessors.isEmpty == false else { return nil }
        var forks: [Int: ConditionalFork] = [:]
        for block in cfg.blocks where block.successors.count == 2 {
            let terminator = rows[block.endIndex - 1]
            let mnemonic = terminator.mnemonic.lowercased()
            guard mnemonic == "cbz" || mnemonic == "cbnz" else { continue }
            let register = terminator.operands.split(separator: ",", maxSplits: 1)
                .first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            forks[block.index] = ConditionalFork(
                register: register, condition: mnemonic == "cbz" ? "==" : "!=",
                taken: block.successors[0], fallthroughBlock: block.successors[1])
        }
        return Self(cfg: cfg,
                    blockAtStart: Dictionary(uniqueKeysWithValues: cfg.blocks.map { ($0.startIndex, $0.index) }),
                    blockAtEnd: Dictionary(uniqueKeysWithValues: cfg.blocks.map { ($0.endIndex - 1, $0.index) }),
                    conditionalForks: forks,
                    referencedXRegisters: referencedXRegisters.sorted())
    }

    /// Cached inferred returns can contain HFA fragments instead of re-reading
    /// registers. Never retain a predecessor's cached SIMD result after its
    /// producer or width authority changed at the join.
    private static func invalidateCachedSIMDResult(
        in state: inout BuilderState, affectedIndices: Set<Int>
    ) {
        func dependsOnAffectedSIMD(_ value: MacIRValue) -> Bool {
            switch value {
            case let .register(name, _):
                guard let view = BuilderState.simdViewWidth(name) else { return false }
                return affectedIndices.contains(view.index)
            case let .abiComposite(_, fragments):
                return fragments.contains(where: dependsOnAffectedSIMD)
            default: return false
            }
        }
        if let result = state.latestABIResultValue, dependsOnAffectedSIMD(result) {
            state.latestABIResultValue = .unknown("unavailable_simd_join_result")
            state.shouldInferVoidReturn = false
        }
    }

    private static func reserveRegisterFloor(_ floor: Int, in state: inout BuilderState) {
        state.registerVersionFloor = max(state.registerVersionFloor, floor)
        state.nextRegisterTemporaryIndex = max(state.nextRegisterTemporaryIndex, floor)
    }

    private static func foldAllocationCounters(from predecessor: BuilderState, into state: inout BuilderState) {
        state.nextRegisterTemporaryIndex = max(state.nextRegisterTemporaryIndex, predecessor.nextRegisterTemporaryIndex)
        state.registerVersionFloor = max(state.registerVersionFloor, predecessor.registerVersionFloor)
        for (register, version) in predecessor.registerVersions {
            state.registerVersions[register] = max(state.registerVersions[register, default: 0], version)
        }
    }

    func incoming(for blockIndex: Int, entry: BuilderState,
                  outgoing: [Int: BuilderState], phis: inout [PhiDraft]) -> BuilderState {
        guard blockIndex != cfg.entryIndex else { return entry }
        let floor = blockIndex * (cfg.blocks.reduce(0) { $0 + $1.instructionRange.count } + 1)
        let predecessors = cfg.blocks[blockIndex].predecessors
        let states = predecessors.compactMap { outgoing[$0] }
        guard let first = states.first,
              predecessors.allSatisfy({ outgoing[$0] != nil ||
                  cfg.backEdges.contains(CFGEdge($0, blockIndex)) }) else {
            var unavailable = entry
            // Entry SP is not a valid default at an unvisited predecessor.
            // Recover only a unanimous emitted definition across SP-free paths;
            // a cycle, missing root, pending writer or disagreement fails closed.
            // This proves the register only, never cached stack coordinates.
            unavailable.invalidateStackCoordinateSystem()
            unavailable.hasExplicitStackWriteback = true
            unavailable.callUnavailableRegisterValues.formUnion(["sp", "wsp"])
            let recoveredSPVersion = pendingStackPointerVersion(entering: blockIndex, outgoing: outgoing)
            if recoveredSPVersion != nil {
                unavailable.callUnavailableRegisterValues.remove("sp")
            }
            for index in 0...30 { unavailable.recordUnmodeledDefiniteWrite(for: "x\(index)") }
            for index in 0...31 { unavailable.callResultVectorWidth[index] = 0 }
            Self.invalidateCachedSIMDResult(in: &unavailable, affectedIndices: Set(0...31))
            for predecessor in states {
                Self.foldAllocationCounters(from: predecessor, into: &unavailable)
            }
            if let recoveredSPVersion {
                unavailable.registerVersions["sp"] = recoveredSPVersion
            }
            Self.reserveRegisterFloor(floor, in: &unavailable)
            return unavailable
        }
        var merged = first
        for predecessor in states.dropFirst() {
            Self.foldAllocationCounters(from: predecessor, into: &merged)
            for value in predecessor.registerNameBindingOrder where merged.registerNameBindingsByValue[value] == nil {
                merged.registerNameBindingsByValue[value] = predecessor.registerNameBindingsByValue[value]
                merged.registerNameBindingOrder.append(value)
            }
            merged.valueTypeHints.merge(predecessor.valueTypeHints) { existing, _ in existing }
        }
        // Cached stack values come from one predecessor only. At a real join
        // (several predecessors, or a back edge not yet visited) another path
        // may have stored to the slot, so no fact may forward across it.
        if predecessors.count > 1 || states.count != predecessors.count {
            merged.invalidateAllStackSlotValues()
        }
        // An escape on any path stays an escape after the join.
        merged.stackAddressEscapedThroughMemory = states.contains { $0.stackAddressEscapedThroughMemory }
        Self.reserveRegisterFloor(floor, in: &merged)
        for index in 0...30 {
            let x = "x\(index)"
            let w = "w\(index)"
            let disagrees = states.dropFirst().contains(where: {
                $0.readRegister(x) != first.readRegister(x) ||
                    $0.readRegister(w) != first.readRegister(w)
            })
            let hasPendingBackedge = states.count != predecessors.count
            if (disagrees || hasPendingBackedge), referencedXRegisters.contains(index),
               states.allSatisfy({ !Self.isUnavailable($0.readRegister(x)) }),
               states.allSatisfy({ !Self.isUnavailable($0.readRegister(w)) }) {
                let destination = merged.writeRegister(x)
                merged.currentIntegerDefinitionByIndex[index]?.isJoinedDefinition = true
                if index == 0 {
                    merged.currentIntegerDefinitionByIndex[0]?.isSyntheticReturnPhi = true
                    // writeRegister also caches ABI producers. This synthetic
                    // join must go through the origin-aware definition check.
                    if merged.latestABIResultValue == destination {
                        merged.latestABIResultValue = nil
                    }
                }
                phis.append(PhiDraft(blockIndex: blockIndex, registerIndex: index,
                                     destination: destination))
            } else if disagrees || hasPendingBackedge {
                merged.recordUnmodeledDefiniteWrite(for: x)
                if index == 0 {
                    // A converged RET still returns an ABI value. The join
                    // lacks a proven producer; it is not a void function.
                    merged.latestABIResultValue = .unknown("unavailable_x0")
                }
            }
        }
        // SP joins like x0-x30, but only where its value can actually differ.
        let spDisagrees = states.dropFirst().contains { $0.readRegister("sp") != first.readRegister("sp") }
        if spDisagrees || (states.count != predecessors.count && spWritingLoopHeaders.contains(blockIndex)) {
            if referencesSP, states.allSatisfy({ !Self.isUnavailable($0.readRegister("sp")) }) {
                let destination = merged.writeRegister("sp")
                phis.append(PhiDraft(blockIndex: blockIndex, registerIndex: 31,
                                     destination: destination, registerName: "sp"))
            } else {
                merged.recordUnmodeledDefiniteWrite(for: "sp")
            }
        }
        // A whole-v read is not a producer identity for partial SIMD results:
        // both an S and a D result can read as the same unavailable-upper marker.
        // Join every view even on scalar plans (whose referencedVRegisters is empty).
        let hasPendingBackedge = states.count != predecessors.count
        let vectorViews: [(name: String, width: Int)] = [
            ("b", 8), ("h", 16), ("s", 32), ("d", 64), ("q", 128), ("v", 128)
        ]
        var affectedSIMDResultIndices: Set<Int> = []
        for index in 0...31 {
            let v = "v\(index)"
            let commonWidth = states.map { state in
                let resultWidth = state.callResultVectorWidth[index] ?? 128
                let preservedWidth = state.permitsNEONBufferCarrier &&
                    state.regionUpperVectorUnavailable.contains(v) ? 64 : 128
                return min(resultWidth, preservedWidth)
            }.min() ?? 0
            if commonWidth == 0 || commonWidth < (first.callResultVectorWidth[index] ?? 128) {
                affectedSIMDResultIndices.insert(index)
            }
            if commonWidth < 128 { merged.callResultVectorWidth[index] = commonWidth }
            let disagrees = vectorViews.contains { view in
                guard view.width <= commonWidth else { return false }
                let register = "\(view.name)\(index)"
                return states.dropFirst().contains {
                    $0.readRegister(register) != first.readRegister(register)
                }
            }
            guard disagrees || hasPendingBackedge else { continue }
            affectedSIMDResultIndices.insert(index)
            if commonWidth == 128, referencedVRegisters.contains(index),
               states.allSatisfy({ !Self.isUnavailable($0.readRegister(v)) }) {
                let destination = merged.writeRegister(v)
                phis.append(PhiDraft(blockIndex: blockIndex, registerIndex: index,
                                     destination: destination, registerName: v, bitWidth: 128))
            } else {
                // Partial scalar/HFA carriers do not have a projection-aware
                // phi here. A zero-width tombstone rejects ALL aliases instead
                // of selecting the first producer. writeRegister clears it on
                // the next real SIMD definition, as for call-result width caps.
                merged.callResultVectorWidth[index] = 0
            }
        }
        Self.invalidateCachedSIMDResult(in: &merged, affectedIndices: affectedSIMDResultIndices)
        // Synthetic phi writes do not establish caller construction. Require a
        // write in every available predecessor; an unseen backedge abstains.
        merged.constructedCallArgumentGPRs = states.count == predecessors.count
            ? states.dropFirst().reduce(first.constructedCallArgumentGPRs) {
                $0.intersection($1.constructedCallArgumentGPRs)
            } : []
        merged.resolvedX0PhiReturnProducers = resolvedX0ReturnProducers(phis, outgoing: outgoing)
        return merged
    }

    /// Resolve only completed predecessor snapshots, including backedges.
    /// One real incoming write suffices under the existing producer heuristic;
    /// this is not an all-path return-contract proof. Entry-only cycles have no
    /// seed. Each node/edge is visited a bounded number of times per join,
    /// without recursive traversal or repeated whole-graph fixed-point scans.
    private func resolvedX0ReturnProducers(_ drafts: [PhiDraft],
                                           outgoing: [Int: BuilderState]) -> Set<MacIRValue> {
        var dependents: [MacIRValue: [MacIRValue]] = [:]
        var producers: Set<MacIRValue> = []
        for draft in drafts where draft.register == "x0" {
            let predecessors = cfg.blocks[draft.blockIndex].predecessors
            let states = predecessors.compactMap { outgoing[$0] }
            guard states.count == predecessors.count,
                  states.allSatisfy({ !Self.isUnavailable($0.readRegister("x0")) }) else { continue }
            for state in states {
                // An entry argument has no current definition and is not a
                // producer. A real w0 write keeps its original width/value.
                guard let definition = state.currentIntegerDefinitionByIndex[0] else { continue }
                if definition.isSyntheticReturnPhi {
                    dependents[definition.value, default: []].append(draft.destination)
                } else {
                    producers.insert(draft.destination)
                }
            }
        }
        var work = Array(producers)
        while let source = work.popLast() {
            for destination in dependents[source] ?? [] where producers.insert(destination).inserted {
                work.append(destination)
            }
        }
        return producers
    }

    struct PhiResolution {
        let phis: [MacIRPhi]
        let retainsControlPresentation: Bool

        fileprivate init(phis: [MacIRPhi], retainsControlPresentation: Bool) {
            self.phis = phis
            self.retainsControlPresentation = retainsControlPresentation
        }
    }

    func resolvedPhis<Row: DecompilerInstructionRow>(_ drafts: [PhiDraft],
                                                      rows: [Row],
                                                      outgoing: [Int: BuilderState],
                                                      instructions: [MacIRInstruction]) -> [MacIRPhi] {
        resolvePhiPresentation(drafts, rows: rows, outgoing: outgoing,
                               instructions: instructions).phis
    }

    func resolvePhiPresentation<Row: DecompilerInstructionRow>(_ drafts: [PhiDraft],
                                                              rows: [Row],
                                                              outgoing: [Int: BuilderState],
                                                              instructions: [MacIRInstruction]) -> PhiResolution {
        let all = drafts.map { draft in
            let block = cfg.blocks[draft.blockIndex]
            let incoming = block.predecessors.sorted().map { predecessor -> MacIRPhi.Incoming in
                let source = rows[cfg.blocks[predecessor].endIndex - 1].address
                let value = outgoing[predecessor]?.readRegister(draft.register)
                    ?? .unknown("unavailable_\(draft.register)")
                return .init(predecessorAddress: source, value: value)
            }
            return MacIRPhi(blockAddress: rows[block.startIndex].address,
                            destination: draft.destination, bitWidth: draft.bitWidth,
                            incoming: incoming)
        }
        var used: Set<MacIRValue> = []
        func record(_ value: MacIRValue) {
            used.insert(value)
            switch value {
            case let .bitTest(inner, _), let .unary(_, inner): record(inner)
            case let .binaryExpression(_, left, right): record(left); record(right)
            case let .signedBitfield(field): record(field.source)
            default: break
            }
        }
        for instruction in instructions {
            switch instruction.operation {
            case let .assign(_, source): record(source)
            case let .binary(_, _, left, right): record(left); record(right)
            case let .load(_, address): record(address)
            case let .store(source, address): record(source); record(address)
            case let .loadWriteback(_, _, baseSource, _, _): record(baseSource)
            case let .storeWriteback(source, _, baseSource, _, _):
                record(source); record(baseSource)
            case let .conditionalBranch(_, left, right, target):
                record(left); record(right); record(target)
            case let .select(_, _, left, right, trueValue, falseValue):
                record(left); record(right); record(trueValue); record(falseValue)
            case let .call(frame, _): frame.bindingValues.forEach(record)
            case let .returnValue(value): if let value { record(value) }
            case let .intrinsic(_, _, arguments): arguments.forEach(record)
            case let .unknown(_, inputs, _, _):
                inputs.mayRead.forEach { record($0.value) }
                inputs.definiteRead.forEach { record($0.value) }
            default: break
            }
        }
        // An incoming value may itself be a phi at a preceding block. Resolve
        // the finite dependency graph without walking source order as execution.
        for _ in 0..<all.count {
            let before = used.count
            for phi in all where used.contains(phi.destination) {
                phi.incoming.forEach { record($0.value) }
            }
            if before == used.count { break }
        }
        let unresolvedReturns = Set(instructions.compactMap { instruction -> UInt64? in
            guard case let .returnValue(.some(.unknown(marker))) = instruction.operation,
                  marker == MacIRIndirectTargetResolution.unresolvedReturnContractMarker else { return nil }
            return instruction.source.address
        })
        // Keep the control renderer when a rejected return was a phi's last
        // consumer. Its old producer identity is presentation evidence only.
        let retainsControlPresentation = cfg.blocks.contains { block in
            guard unresolvedReturns.contains(rows[block.endIndex - 1].address),
                  let state = outgoing[block.index],
                  let definition = state.currentIntegerDefinitionByIndex[0],
                  definition.isSyntheticReturnPhi,
                  state.latestABIResultValue == nil,
                  !state.hasUnmodeledABIResultWrite,
                  !Self.isUnavailable(state.readRegister("x0")),
                  state.resolvedX0PhiReturnProducers.contains(definition.value),
                  !used.contains(definition.value) else { return false }
            return all.contains { $0.destination == definition.value }
        }
        return PhiResolution(phis: all.filter { used.contains($0.destination) },
                             retainsControlPresentation: retainsControlPresentation)
    }

    /// Lower one exact two-arm diamond at its first use. The select's source
    /// is the real join move, so no synthetic instruction or duplicate source
    /// identity is introduced. Other conflicting uses remain unavailable.
    func selectForJoinMove<Row: DecompilerInstructionRow>(
        rowIndex: Int, row: Row, outgoing: [Int: BuilderState],
        state: inout BuilderState
    ) -> MacIROperation? {
        guard let joinIndex = blockAtStart[rowIndex],
              row.mnemonic.lowercased() == "mov" else { return nil }
        let operands = row.operands.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard operands.count == 2, Self.isGPR(operands[0]), Self.isGPR(operands[1]) else { return nil }
        let predecessors = cfg.blocks[joinIndex].predecessors
        let matchingForks = conditionalForks.filter { _, fork in
            Set([fork.taken, fork.fallthroughBlock]) == Set(predecessors)
        }
        guard predecessors.count == 2,
              matchingForks.count == 1,
              let forkEntry = matchingForks.first,
              cfg.blocks[forkEntry.value.taken].predecessors == [forkEntry.key],
              cfg.blocks[forkEntry.value.fallthroughBlock].predecessors == [forkEntry.key],
              CFGBuilder.dominates(forkEntry.key, joinIndex, domTree: cfg.domTree),
              let forkState = outgoing[forkEntry.key],
              let takenState = outgoing[forkEntry.value.taken],
              let fallthroughState = outgoing[forkEntry.value.fallthroughBlock] else { return nil }
        let trueValue = takenState.readRegister(operands[1])
        let falseValue = fallthroughState.readRegister(operands[1])
        guard trueValue != falseValue,
              !Self.isUnavailable(trueValue), !Self.isUnavailable(falseValue) else { return nil }
        let destination = state.writeRegister(operands[0])
        return .select(destination: destination, condition: forkEntry.value.condition,
                       left: forkState.readRegister(forkEntry.value.register),
                       right: .immediate(0), trueValue: trueValue, falseValue: falseValue)
    }

    private static func isUnavailable(_ value: MacIRValue) -> Bool {
        if case .unknown = value { return true }
        return false
    }

    private static func isGPR(_ text: String) -> Bool {
        guard let prefix = text.first, prefix == "x" || prefix == "w",
              let index = Int(text.dropFirst()) else { return false }
        return (0...30).contains(index) && text == "\(prefix)\(index)"
    }

    private static func xRegisterIndex(_ text: String) -> Int? {
        guard text.first == "x", let index = Int(text.dropFirst()),
              (0...30).contains(index), text == "x\(index)" else { return nil }
        return index
    }

    private static func address(_ text: String) -> UInt64? {
        if text.hasPrefix("0x") { return UInt64(text.dropFirst(2), radix: 16) }
        return UInt64(text)
    }

    private static func immediate(_ text: String) -> Int64? {
        guard text.hasPrefix("#") else { return nil }
        let number = String(text.dropFirst())
        if number.hasPrefix("0x") { return Int64(number.dropFirst(2), radix: 16) }
        return Int64(number)
    }
}

/// Safety floor for functions outside the phi composer's admission. A source
/// definition is usable only when every reaching predecessor agrees and the
/// linear builder holds that definition or can recover its lifted producer.
/// Disagreement never selects one
/// predecessor and never rewinds SSA allocation or accumulated function metadata.
// Passive census observations of the original execution, never proof inputs.
// Only an explicitly scoped test sink enables copying; the default is nil.
enum RejectedCFGDiagnostics {
    struct Entry: Sendable {
        let unavailable: Set<Int>
        let nonlexical: Bool
        let producers: [Int: Int]
    }
    struct Snapshot: Sendable {
        let value: MacIRValue
        let width: Int
        let isJoinedDefinition: Bool
        let isSyntheticReturnPhi: Bool

        init(value: MacIRValue, width: Int, isJoinedDefinition: Bool = false,
             isSyntheticReturnPhi: Bool = false) {
            self.value = value
            self.width = width
            self.isJoinedDefinition = isJoinedDefinition
            self.isSyntheticReturnPhi = isSyntheticReturnPhi
        }
    }
    struct OrdinaryDefinition {
        let value: MacIRValue
        let width: Int
        let type: String
        let zeroHigh: Bool
    }
    // Events are delivered synchronously. Planner value records are copied,
    // never planner instances or mutable BuilderState references.
    enum Event {
        case plan(id: UUID, addresses: [UInt64], ranges: [Range<Int>],
                  successors: [[Int]], predecessors: [[Int]], precedingRows: [[Int]],
                  effects: [[Int]], entries: [Int: Entry], incoming: [[Int]?],
                  callRows: Set<Int>, hasUnenumeratedTransfer: Bool)
        case modeled(id: UUID, row: Int)
        case snapshot(id: UUID, row: Int, cell: Int, definition: Snapshot)
        case missingSnapshot(id: UUID, row: Int, cell: Int, producer: Int)
        case comparison(id: UUID, row: Int, cell: Int, producer: Int,
                        snapshot: Snapshot, current: Snapshot?, needsRepair: Bool)
        case preservationVisit(id: UUID, row: Int, cell: Int, producer: Int,
                               prior: Int, outcome: String, modeled: Bool?,
                               writesCell: Bool?, predecessors: [Int]?)
        case preservationResult(id: UUID, row: Int, cell: Int, producer: Int, preserved: Bool)
        case restored(id: UUID, row: Int, cell: Int, definition: Snapshot)
        case physicalAttempt(id: UUID, start: UInt64, addresses: [UInt64],
                             ranges: [Range<Int>], predecessors: [[Int]], successors: [[Int]],
                             backEdges: [CFGEdge], file: String, line: Int)
        case physicalRows(id: UUID, rows: [RegionalPhysicalStatePlan.Row])
        case physicalCertificate(id: UUID, provedPositions: Set<RegionalProvedPosition>,
                                 liveIncoming: [[UInt8]], liveAfter: [[UInt8]])
        case physicalEnd(id: UUID, succeeded: Bool)
        case ordinaryProofBegin(id: UUID, start: UInt64, file: String, line: Int)
        case ordinaryProofEnd(id: UUID, succeeded: Bool)
        case ordinaryAttempt(id: UUID, start: UInt64, addresses: [UInt64],
                             parameters: [MacIRFunctionParameter], file: String, line: Int)
        case ordinaryFacts(id: UUID, plannerCompleted: Bool,
                           definitions: [RegionalOrdinaryValuePlan.DefinitionID: OrdinaryDefinition],
                           uses: [RegionalOrdinaryValuePlan.UseBinding],
                           edges: [RegionalOrdinaryValuePlan.EdgeBinding],
                           phiInputs: [RegionalOrdinaryValuePlan.DefinitionID: [CFGEdge: RegionalOrdinaryValuePlan.DefinitionID]],
                           before: [[RegionalOrdinaryValuePlan.DefinitionID?]],
                           after: [[RegionalOrdinaryValuePlan.DefinitionID?]],
                           replacements: [RegionalOrdinaryValuePlan.DefinitionID: RegionalOrdinaryValuePlan.DefinitionID])
        case nativeProofBegin(id: UUID, start: UInt64, file: String, line: Int)
        case nativeProofEnd(id: UUID, succeeded: Bool)
        case nativeAttempt(id: UUID, start: UInt64, addresses: [UInt64],
                           ranges: [Range<Int>], predecessors: [[Int]], successors: [[Int]],
                           backEdges: [CFGEdge], parameters: [MacIRFunctionParameter], file: String, line: Int)
        case nativeUse(id: UUID, binding: DecodedScalarNativeValuePlan.UseBinding)
        case nativeFacts(id: UUID, plannerCompleted: Bool,
                         definitions: [DecodedScalarNativeValuePlan.DefinitionID: OrdinaryDefinition],
                         edges: [DecodedScalarNativeValuePlan.EdgeBinding],
                         phiInputs: [DecodedScalarNativeValuePlan.DefinitionID: [CFGEdge: DecodedScalarNativeValuePlan.DefinitionID]],
                         before: [[DecodedScalarNativeValuePlan.DefinitionID?]],
                         after: [[DecodedScalarNativeValuePlan.DefinitionID?]],
                         replacements: [DecodedScalarNativeValuePlan.DefinitionID: DecodedScalarNativeValuePlan.DefinitionID])
        case guardObserved(kind: String, name: String, recorded: Bool, file: String, line: Int)
        case classificationBegin(id: UUID, file: String, line: Int)
        case classificationEnd(id: UUID, refusal: RegionalRefusal?)
        case buildBegin(id: UUID, name: String, start: UInt64)
        case buildEnd(id: UUID)
        case rowBegin(buildID: UUID, row: Int, address: UInt64)
        case rowEnd(buildID: UUID, row: Int)
        case entryRead(register: String, parameter: MacIRFunctionParameter,
                       sourceWidth: Int?, requestedWidth: Int?, projectedValue: MacIRValue,
                       file: String, line: Int)
    }
    @TaskLocal static var sink: (@Sendable (Event) -> Void)?
}

struct RejectedCFGStatePlan {
    private struct Entry {
        let unavailable: Set<Int>
        let nonlexical: Bool
        var producers: [Int: Int] = [:]
    }

    // Physical integer registers, SP, SIMD low/high halves, NZCV and memory.
    // Separating the SIMD halves preserves ABI-saved D8-D15 across calls.
    private static let flags = 96
    private static let memory = 97
    private static let cellCount = 98
    private static let entryDefinition = -1
    private static let mixedDefinition = -2
    private let entries: [Int: Entry]
    private var effects: [[Int]] = []
    private var precedingRows: [[Int]] = []
    private var modeledRows: Set<Int> = []
    private var callRows: Set<Int> = []
    private var producerSnapshots: [Int: [Int: IntegerRegisterDefinition]] = [:]
    // No identifier or diagnostic collection is allocated while capture is off.
    private var diagnosticID: UUID? = nil

    init<Row: DecompilerInstructionRow>(rows: [Row], jumpTables: [UInt64: [UInt64]]) {
        guard !rows.isEmpty else { entries = [:]; return }
        var indexByAddress: [UInt64: Int] = [:]
        for (index, row) in rows.enumerated() where indexByAddress[row.address] == nil {
            indexByAddress[row.address] = index
        }
        var leaders: Set<Int> = [0]
        var transfers: [Int: [Int]] = [:]
        var effects: [[Int]] = []
        var undecoded: Set<Int> = []
        var opaqueFlags: Set<Int> = []
        var hasUnenumeratedTransfer = false
        for (index, row) in rows.enumerated() {
            let mnemonic = row.mnemonic.lowercased()
            let operands = MacIRBuilder.splitOperands(row.operands)
            if ["bl", "blr", "blraa", "blrab", "blraaz", "blrabz"].contains(mnemonic) {
                callRows.insert(index)
            }
            effects.append(Self.writes(mnemonic: mnemonic, operands: operands))
            if Self.hasOpaqueFlagWrite(mnemonic: mnemonic, operands: operands) { opaqueFlags.insert(index) }
            if mnemonic == "unknown" || mnemonic == "unavailable" {
                undecoded.insert(index)
            }
            let conditional = mnemonic.hasPrefix("b.") || mnemonic.hasPrefix("bc.")
                || ["cbz", "cbnz", "tbz", "tbnz"].contains(mnemonic)
            let indirect = ["br", "braa", "brab", "braaz", "brabz"].contains(mnemonic)
            let returning = mnemonic.hasPrefix("ret") || mnemonic.hasPrefix("eret")
            let noReturn = mnemonic == "bl" && operands.first.map { NoReturnCatalog.isNoReturn($0) } == true
            guard conditional || mnemonic == "b" || indirect || returning || noReturn else { continue }
            if index + 1 < rows.count { leaders.insert(index + 1) }
            var targets: [Int] = []
            if conditional || mnemonic == "b" {
                if let operand = operands.last, let address = Self.address(operand) {
                    if let target = indexByAddress[address] { targets.append(target) }
                } else {
                    hasUnenumeratedTransfer = true
                }
            } else if indirect {
                if let addresses = jumpTables[row.address], !addresses.isEmpty {
                    for address in addresses {
                        if let target = indexByAddress[address] { targets.append(target) }
                        else { hasUnenumeratedTransfer = true }
                    }
                } else {
                    hasUnenumeratedTransfer = true
                }
            }
            if conditional, index + 1 < rows.count { targets.append(index + 1) }
            transfers[index] = Array(Set(targets)).sorted()
            leaders.formUnion(targets)
        }
        // Only enumerated in-function destinations contribute incoming edges.
        // External destinations and opaque indirect transfers leave this graph.
        let starts = leaders.sorted()
        let blockByStart = Dictionary(uniqueKeysWithValues: starts.enumerated().map { ($1, $0) })
        let ranges = starts.enumerated().map { block, start in
            start..<(block + 1 < starts.count ? starts[block + 1] : rows.count)
        }
        var successors = Array(repeating: [Int](), count: starts.count)
        var predecessors = successors
        var generated = Array(repeating: [Int: Int](), count: starts.count)
        for (block, range) in ranges.enumerated() {
            let last = range.upperBound - 1
            let targets = transfers[last] ?? (last + 1 < rows.count ? [last + 1] : [])
            successors[block] = targets.compactMap { blockByStart[$0] }
            for successor in successors[block] { predecessors[successor].append(block) }
            for row in range {
                for cell in effects[row] {
                    generated[block][cell] = undecoded.contains(row)
                        || (cell == Self.flags && opaqueFlags.contains(row)) ? Self.mixedDefinition : row
                }
            }
        }
        self.effects = effects
        precedingRows = Array(repeating: [], count: rows.count)
        for (block, range) in ranges.enumerated() {
            for row in range {
                precedingRows[row] = row == range.lowerBound
                    ? predecessors[block].map { ranges[$0].upperBound - 1 } : [row - 1]
            }
        }
        let initial = Array(repeating: Self.entryDefinition, count: Self.cellCount)
        // nil is unreachable, not a missing predecessor to be guessed. The
        // fixed point includes backedges before any body operand is captured.
        var incoming = Array<[Int]?>(repeating: nil, count: starts.count)
        var outgoing = incoming
        var work = [0]
        var queued: Set<Int> = [0]
        var cursor = 0
        while cursor < work.count {
            let block = work[cursor]
            cursor += 1
            queued.remove(block)
            var merged: [Int]? = block == 0 ? initial : nil
            for predecessor in predecessors[block] {
                guard let values = outgoing[predecessor] else { continue }
                if merged == nil {
                    merged = values
                } else {
                    for cell in 0..<Self.cellCount where merged?[cell] != values[cell] {
                        merged?[cell] = Self.mixedDefinition
                    }
                }
            }
            guard var values = merged else { continue }
            incoming[block] = values
            for (cell, definition) in generated[block] { values[cell] = definition }
            if outgoing[block] != values {
                outgoing[block] = values
                for successor in successors[block] where queued.insert(successor).inserted {
                    work.append(successor)
                }
            }
        }
        var lexical = initial
        var result: [Int: Entry] = [:]
        var poisonedStarts: [UInt64] = []
        for (block, start) in starts.enumerated() {
            let nonlexical = block == 0 ? !predecessors[block].isEmpty : predecessors[block] != [block - 1]
            if predecessors[block].count > 1 || nonlexical, let values = incoming[block] {
                let unavailable = Set((0..<Self.cellCount).filter {
                    values[$0] == Self.mixedDefinition || values[$0] != lexical[$0]
                })
                // Retain equal nominal identities too: a skipped textual join
                // may have tombstoned the actual physical register meanwhile.
                let producers = hasUnenumeratedTransfer ? [:] : Dictionary(
                    uniqueKeysWithValues: (0...30).compactMap { cell -> (Int, Int)? in
                        values[cell] >= 0 ? (cell, values[cell]) : nil
                    })
                if !unavailable.isEmpty || !producers.isEmpty {
                    result[start] = Entry(unavailable: unavailable, nonlexical: nonlexical,
                                          producers: producers)
                }
            } else if block != 0, incoming[block] == nil, hasUnenumeratedTransfer {
                // An opaque transfer may enter otherwise unreachable code. Do
                // not carry the preceding textual block's facts into that block.
                result[start] = Entry(unavailable: Set(0..<Self.cellCount), nonlexical: true)
                poisonedStarts.append(rows[start].address)
            }
            for (cell, definition) in generated[block] { lexical[cell] = definition }
        }
        entries = result
        // Copy the already computed fixed point and graph; do not rerun either.
        if let sink = RejectedCFGDiagnostics.sink {
            let id = UUID()
            diagnosticID = id
            sink(.plan(id: id, addresses: rows.map(\.address), ranges: ranges,
                successors: successors, predecessors: predecessors, precedingRows: precedingRows,
                effects: effects, entries: result.mapValues {
                    .init(unavailable: $0.unavailable, nonlexical: $0.nonlexical, producers: $0.producers)
                }, incoming: incoming, callRows: callRows,
                hasUnenumeratedTransfer: hasUnenumeratedTransfer))
        }
        if hasUnenumeratedTransfer,
           ProcessInfo.processInfo.environment["MACSCOPE_C2_OUT"] != nil {
            let poisoned = poisonedStarts.map { String($0, radix: 16) }.joined(separator: ",")
            print("REJECTED_CFG_UNENUMERATED start=\(String(rows[0].address, radix: 16)) end=\(String(rows[rows.count - 1].address, radix: 16)) rows=\(rows.count) poisoned=\(poisonedStarts.count) blocks=\(poisoned)")
        }
    }

    /// Capture only lifted values, never a BuilderState or memory facts.
    mutating func capture(at row: Int, operation: MacIROperation, state: BuilderState) {
        guard !callRows.contains(row) else { return }
        switch operation {
        case .unknown, .call: return
        default: break
        }
        modeledRows.insert(row)
        if let sink = RejectedCFGDiagnostics.sink, let id = diagnosticID {
            sink(.modeled(id: id, row: row))
        }
        for cell in effects[row] where cell <= 30 {
            guard !state.unavailableRegisterValues.contains("x\(cell)"),
                  !state.unavailableRegisterValues.contains("w\(cell)"),
                  let definition = state.currentIntegerDefinitionByIndex[cell],
                  definition.width == 32 || definition.width == 64 else { continue }
            producerSnapshots[row, default: [:]][cell] = definition
            if let sink = RejectedCFGDiagnostics.sink, let id = diagnosticID {
                sink(.snapshot(id: id, row: row, cell: cell,
                    definition: .init(value: definition.value, width: definition.width,
                        isJoinedDefinition: definition.isJoinedDefinition, isSyntheticReturnPhi: definition.isSyntheticReturnPhi)))
            }
        }
    }

    /// The fixed point proves producer agreement. This walk additionally proves
    /// that every edge since that producer has actually been lifted and contains
    /// neither an opaque operation, a call, nor a physical alias write. Future
    /// (not yet lifted) paths cannot supply preservation authority.
    private func preserves(_ cell: Int, producer: Int, entering row: Int) -> Bool {
        var work = precedingRows[row]
        var visited: Set<Int> = []
        guard !work.isEmpty else {
            if let sink = RejectedCFGDiagnostics.sink, let id = diagnosticID {
                sink(.preservationResult(id: id, row: row, cell: cell, producer: producer, preserved: false))
            }
            return false
        }
        while let prior = work.popLast() {
            if prior == producer {
                if let sink = RejectedCFGDiagnostics.sink, let id = diagnosticID {
                    sink(.preservationVisit(id: id, row: row, cell: cell, producer: producer,
                        prior: prior, outcome: "producer", modeled: nil,
                        writesCell: nil, predecessors: nil))
                }
                continue
            }
            guard visited.insert(prior).inserted else {
                if let sink = RejectedCFGDiagnostics.sink, let id = diagnosticID {
                    sink(.preservationVisit(id: id, row: row, cell: cell, producer: producer,
                        prior: prior, outcome: "alreadyVisited", modeled: nil,
                        writesCell: nil, predecessors: nil))
                }
                continue
            }
            // Preserve the original guard order and short-circuit behavior.
            // Unevaluated predicates are nil, not extra diagnostic queries.
            guard modeledRows.contains(prior) else {
                if let sink = RejectedCFGDiagnostics.sink, let id = diagnosticID {
                    sink(.preservationVisit(id: id, row: row, cell: cell, producer: producer,
                        prior: prior, outcome: "unmodeled", modeled: false,
                        writesCell: nil, predecessors: nil))
                    sink(.preservationResult(id: id, row: row, cell: cell, producer: producer, preserved: false))
                }
                return false
            }
            guard !effects[prior].contains(cell) else {
                if let sink = RejectedCFGDiagnostics.sink, let id = diagnosticID {
                    sink(.preservationVisit(id: id, row: row, cell: cell, producer: producer,
                        prior: prior, outcome: "write", modeled: true,
                        writesCell: true, predecessors: nil))
                    sink(.preservationResult(id: id, row: row, cell: cell, producer: producer, preserved: false))
                }
                return false
            }
            guard !precedingRows[prior].isEmpty else {
                if let sink = RejectedCFGDiagnostics.sink, let id = diagnosticID {
                    sink(.preservationVisit(id: id, row: row, cell: cell, producer: producer,
                        prior: prior, outcome: "noPredecessor", modeled: true,
                        writesCell: false, predecessors: []))
                    sink(.preservationResult(id: id, row: row, cell: cell, producer: producer, preserved: false))
                }
                return false
            }
            if let sink = RejectedCFGDiagnostics.sink, let id = diagnosticID {
                sink(.preservationVisit(id: id, row: row, cell: cell, producer: producer,
                    prior: prior, outcome: "preserved", modeled: true,
                    writesCell: false, predecessors: precedingRows[prior]))
            }
            work.append(contentsOf: precedingRows[prior])
        }
        if let sink = RejectedCFGDiagnostics.sink, let id = diagnosticID {
            sink(.preservationResult(id: id, row: row, cell: cell, producer: producer, preserved: true))
        }
        return true
    }

    /// Return true at a boundary so adjacency-only arithmetic rewrites reset.
    func reconcile(at row: Int, state: inout BuilderState) -> Bool {
        guard let entry = entries[row] else { return false }
        var restored: [Int: IntegerRegisterDefinition] = [:]
        var unavailable = entry.unavailable
        for (cell, producer) in entry.producers {
            guard let snapshot = producerSnapshots[producer]?[cell] else {
                if let sink = RejectedCFGDiagnostics.sink, let id = diagnosticID {
                    sink(.missingSnapshot(id: id, row: row, cell: cell, producer: producer))
                }
                continue
            }
            let current = state.currentIntegerDefinitionByIndex[cell]
            let needsRepair = entry.unavailable.contains(cell)
                || state.unavailableRegisterValues.contains("x\(cell)")
                || state.unavailableRegisterValues.contains("w\(cell)")
                || current?.value != snapshot.value || current?.width != snapshot.width
            if let sink = RejectedCFGDiagnostics.sink, let id = diagnosticID {
                sink(.comparison(id: id, row: row, cell: cell, producer: producer,
                    snapshot: .init(value: snapshot.value, width: snapshot.width,
                        isJoinedDefinition: snapshot.isJoinedDefinition, isSyntheticReturnPhi: snapshot.isSyntheticReturnPhi),
                    current: current.map { .init(value: $0.value, width: $0.width,
                        isJoinedDefinition: $0.isJoinedDefinition, isSyntheticReturnPhi: $0.isSyntheticReturnPhi) }, needsRepair: needsRepair))
            }
            guard needsRepair else { continue }
            // A prior restoration can change the physical value without a
            // nominal write. Failed preservation must tombstone that mismatch.
            unavailable.insert(cell)
            if preserves(cell, producer: producer, entering: row) {
                restored[cell] = snapshot
            }
        }
        guard !unavailable.isEmpty else { return false }
        // Invalidate stale ancillary facts even for a repaired physical cell.
        // Cached return/selector/memory evidence is not part of the snapshot.
        let cachedResult = state.latestABIResultValue
        // Stack-argument values lose their carrier in their expression. Retain
        // that ownership before invalidating the register/binding dictionaries.
        let cachedCarrierUnavailable = cachedResult.map { value in
            (unavailable.contains(0) && state.currentIntegerDefinitionByIndex[0]?.value == value)
                || (unavailable.contains(32) && ["s0", "d0"].contains {
                    state.currentEntryStackArgumentByScalarFPRegister[$0] == value
                })
        } ?? false
        for index in 0...30 where unavailable.contains(index) {
            let prior = state.currentIntegerDefinitionByIndex[index]
            let marker = MacIRValue.unknown("unavailable_x\(index)")
            let wasAvailable = !state.unavailableRegisterValues.contains("x\(index)")
                && !state.unavailableRegisterValues.contains("w\(index)")
            let retainArgumentSlot = index < 8 && (
                prior?.value == marker
                    || (wasAvailable && (prior != nil
                        || state.parameters.contains { $0.bindingID == .gpr(index) }))
            )
            state.recordUnmodeledDefiniteWrite(for: "x\(index)")
            if retainArgumentSlot {
                // The physical tombstone still governs every ordinary read.
                // Call binding alone retains this slot as explicit uncertainty;
                // real writes and call clobbers already replace/remove the record.
                state.currentIntegerDefinitionByIndex[index] = IntegerRegisterDefinition(
                    value: marker, width: 64)
            }
        }
        for (index, snapshot) in restored {
            state.currentIntegerDefinitionByIndex[index] = snapshot
            if let sink = RejectedCFGDiagnostics.sink, let id = diagnosticID {
                sink(.restored(id: id, row: row, cell: index,
                    definition: .init(value: snapshot.value, width: snapshot.width,
                        isJoinedDefinition: snapshot.isJoinedDefinition, isSyntheticReturnPhi: snapshot.isSyntheticReturnPhi)))
            }
            for prefix in ["x", "w"] {
                state.unavailableRegisterValues.remove("\(prefix)\(index)")
                state.callUnavailableRegisterValues.remove("\(prefix)\(index)")
            }
        }
        if unavailable.contains(31) {
            state.recordUnmodeledDefiniteWrite(for: "sp")
            state.callUnavailableRegisterValues.formUnion(["sp", "wsp"])
            // Plain [sp,#offset] must not fold through a lexical stack depth.
            state.hasExplicitStackWriteback = true
        }
        for index in 0...31 {
            if unavailable.contains(32 + index) {
                for prefix in ["b", "h", "s", "d", "q", "v"] {
                    let register = "\(prefix)\(index)"
                    state.unavailableRegisterValues.insert(register)
                    state.callUnavailableRegisterValues.insert(register)
                    state.vectorScalarCallUnavailableRegisterValues.insert(register)
                    state.currentEntryStackArgumentByScalarFPRegister.removeValue(forKey: register)
                }
                state.callResultVectorWidth[index] = 0
            } else if unavailable.contains(64 + index) {
                state.callResultVectorWidth[index] = min(state.callResultVectorWidth[index] ?? 128, 64)
                for prefix in ["q", "v"] {
                    state.callUnavailableRegisterValues.insert("\(prefix)\(index)")
                    state.vectorScalarCallUnavailableRegisterValues.insert("\(prefix)\(index)")
                }
            }
        }
        if unavailable.contains(Self.memory) { state.invalidateAllStackSlotValues() }
        if unavailable.contains(Self.flags) {
            state.lastComparison = nil
            state.lastAdjacentComparison = nil
            state.pendingConditionalCompare = nil
            state.sawConditionalCompareSinceComparison = true
        } else if entry.nonlexical {
            state.lastAdjacentComparison = nil
            state.pendingConditionalCompare = nil
        }
        if entry.nonlexical { state.lastDivision = nil }
        // Register invalidation must not turn a missing result into proof of
        // void, or leave a cached return referring to a bypassed definition.
        if let cachedResult {
            if cachedCarrierUnavailable || Self.depends(cachedResult, on: unavailable) {
                state.latestABIResultValue = .unknown(
                    state.callerReturnWidth == nil && state.authoritativeReturnLocation == nil
                        && !state.admitsInstructionReturnProducer
                        ? MacIRIndirectTargetResolution.unresolvedReturnContractMarker
                        : "unavailable_join_result")
                state.shouldInferVoidReturn = false
            } else {
                state.latestABIResultValue = cachedResult
            }
        } else if unavailable.contains(0) {
            state.latestABIResultValue = .unknown(
                state.callerReturnWidth == nil && state.authoritativeReturnLocation == nil
                    && !state.admitsInstructionReturnProducer
                    ? MacIRIndirectTargetResolution.unresolvedReturnContractMarker : "unavailable_join_result")
            state.shouldInferVoidReturn = false
        }
        state.provenSwitchSelectors = state.provenSwitchSelectors.filter {
            !Self.depends($0.value, on: unavailable)
        }
        return row != 0 || !unavailable.isEmpty
    }

    private static func depends(_ value: MacIRValue, on cells: Set<Int>) -> Bool {
        switch value {
        case let .register(name, _): return registerCells(name).contains(where: cells.contains)
        case let .argument(binding):
            switch binding.kind {
            case .gpr: return cells.contains(binding.value)
            case .simd: return cells.contains(32 + binding.value)
            case .entryStack: return cells.contains(memory) || cells.contains(31)
            }
        case .argumentFragment: return !cells.isEmpty
        case let .abiComposite(_, fragments): return fragments.contains { depends($0, on: cells) }
        case let .unary(_, inner), let .bitTest(inner, _): return depends(inner, on: cells)
        case let .binaryExpression(_, left, right): return depends(left, on: cells) || depends(right, on: cells)
        case let .signedBitfield(field): return depends(field.source, on: cells)
        case .stackSlot: return cells.contains(memory) || cells.contains(31)
        default: return false
        }
    }

    private static func registerCells(_ register: String) -> [Int] {
        let name = register.lowercased()
        if name == "sp" || name == "wsp" { return [31] }
        if name == "fp" { return [29] }
        if name == "lr" { return [30] }
        if let view = MacIRBuilder.integerRegisterView(name) { return [view.index] }
        if let view = BuilderState.simdViewWidth(name) {
            return view.width > 64 ? [32 + view.index, 64 + view.index] : [32 + view.index]
        }
        if let index = MacIRBuilder.vectorRegisterIndex(name) { return [32 + index, 64 + index] }
        return []
    }

    private static func writes(mnemonic: String, operands: [String]) -> [Int] {
        if mnemonic == "unknown" || mnemonic == "unavailable" { return Array(0..<cellCount) }
        var registers = MacIRBuilder.argumentRegisterWrites(mnemonic: mnemonic, operands: operands)
        if let writeback = MacIRBuilder.explicitMemoryWritebackBase(operands: operands) {
            registers.append(writeback)
        }
        if MacIRBuilder.unknownClaimsFirstOperandWrite(mnemonic: mnemonic),
           let destination = MacIRBuilder.firstOperandWriteForUnknown(mnemonic: mnemonic, operands: operands) {
            registers.append(destination)
        }
        var cells = Set(registers.flatMap(registerCells))
        // Any SIMD write changes the physical carrier, even when the legacy
        // lifter keeps only one scalar view available to later reads.
        for register in registers {
            if let view = BuilderState.simdViewWidth(register) { cells.insert(64 + view.index) }
        }
        if MacIRBuilder.writesNZCVFlags(mnemonic) || ["ccmp", "ccmn", "fccmp", "fccmpe"].contains(mnemonic)
            || hasOpaqueFlagWrite(mnemonic: mnemonic, operands: operands) {
            cells.insert(flags)
        }
        if ["bl", "blr", "blraa", "blrab", "blraaz", "blrabz"].contains(mnemonic) {
            cells.formUnion(0...18)
            cells.insert(30)
            cells.insert(flags)
            cells.insert(memory)
            for index in 0...31 {
                if !(8...15).contains(index) { cells.insert(32 + index) }
                cells.insert(64 + index)
            }
        }
        if MacIRBuilder.unmodeledMemoryWritePrefixes.contains(where: mnemonic.hasPrefix) {
            cells.insert(memory)
        }
        return cells.sorted()
    }

    private static func hasOpaqueFlagWrite(mnemonic: String, operands: [String]) -> Bool {
        ["rmif", "setf8", "setf16", "cfinv", "axflag", "xaflag"].contains(mnemonic)
            || (mnemonic == "msr" && operands.first?.lowercased() == "nzcv")
    }

    private static func address(_ operand: String) -> UInt64? {
        let text = operand.trimmingCharacters(in: .whitespaces)
        let number = text.hasPrefix("#") ? String(text.dropFirst()) : text
        if number.hasPrefix("0x") { return UInt64(number.dropFirst(2), radix: 16) }
        return UInt64(number)
    }
}

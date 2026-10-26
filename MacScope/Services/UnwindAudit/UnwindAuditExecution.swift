import Foundation

struct UnwindAuditObservation {
    let pc: UInt64
    let recovered: [String: UnwindAuditValue]
    let certain: Bool
}

struct UnwindAuditExecutionResult {
    let observations: [UnwindAuditObservation]
    let scope: String
    let instructionCount: Int
    let steps: Int
    let loopHeader: UInt64?
    let loopMemberCount: Int
    let loopVisits: Int
    let loopClosures: Int
}

/// Bounded path exploration. Recovery rules are evaluated independently at the original PC.
enum UnwindAuditExecution {
    static func run(
        instructions: [UnwindAuditInstruction], mode: String,
        calleeEntries: Set<UInt64>, limits: UnwindAuditLimits,
        model: UnwindAuditModel = .boundedLoops,
        recover: (UnwindAuditMachine, UInt64) throws -> [String: UnwindAuditValue]
    ) throws -> UnwindAuditExecutionResult {
        func failure(_ code: String, _ message: String, _ index: Int? = nil) -> UnwindAuditModelError {
            UnwindAuditModelError(code: code, message: message,
                                 address: index.flatMap { instructions.indices.contains($0) ? instructions[$0].address : nil })
        }
        guard !instructions.isEmpty, instructions.count <= limits.maxInstructions else {
            throw failure("function_instruction_limit", "Function has no instructions or exceeds its instruction budget")
        }
        for (index, ins) in instructions.enumerated() {
            let expected = instructions[0].address.addingReportingOverflow(UInt64(index) * 4)
            guard !expected.overflow, ins.address == expected.partialValue, ins.address % 4 == 0 else {
                throw failure("unaligned_function_range", "Instruction addresses must be a contiguous aligned range", index)
            }
        }
        let returns = instructions.indices.filter { instructions[$0].kind == "ret" }
        guard let lastReturn = returns.last,
              instructions[(lastReturn + 1)...].allSatisfy({ $0.kind == "nop" }) else {
            throw failure("cfg_return_shape_not_modeled", "RET x30 terminals with only NOP tails are required", 0)
        }
        let hasBranches = instructions.contains { $0.kind == "b" || $0.kind == "bcond" }
        let hasCalls = instructions.contains { $0.kind == "bl" }
        if model == .boundedLoopCalls {
            for (index, ins) in instructions.enumerated() where ins.kind == "b" {
                let target = try branchTarget(ins)
                if target < instructions[0].address || target > instructions[instructions.count - 1].address {
                    throw failure("cfg_edge_not_modeled", "External tail branch is outside this model", index)
                }
            }
        }
        if mode == "frameless" && hasCalls {
            throw failure("frameless_nonleaf_not_modeled", "Frameless recovery requires a leaf function", 0)
        }
        if mode == "frame" && !hasCalls {
            throw failure("no_supported_observation", "Frame recovery requires a direct-call observation", 0)
        }
        let leaf = mode == "frameless" || (mode == "dwarf" && !hasCalls)
        let scope = leaf ? "modeled_leaf_body" : "synchronous_call_sites"
        var bodyStart = 0
        if !hasBranches || !leaf {
            for index in 0..<returns[0] {
                if setup(instructions[index]) { bodyStart = index + 1 }
                else if instructions[index].kind != "nop" { break }
            }
        } else if instructions[0].kind == "sub", instructions[0].rd == 31,
                  instructions[0].rn == 31, instructions[0].immediate > 0 {
            bodyStart = 1
        }
        var regions: [(start: Int, ret: Int)] = []
        var leafTotals: [Int64] = []
        for ret in returns {
            var end = ret
            let lower = regions.last.map { $0.ret + 1 } ?? bodyStart
            var total: Int64 = 0
            if ret > lower {
                for index in stride(from: ret - 1, through: lower, by: -1) {
                    let ins = instructions[index]
                    if !hasBranches || !leaf {
                        if teardown(ins) { end = index }
                        else if ins.kind != "nop" { break }
                    } else if bodyStart == 1 {
                        if leafRestore(ins) {
                            end = index
                            let next = total.addingReportingOverflow(ins.immediate)
                            guard !next.overflow else { throw failure("cfg_return_shape_not_modeled", "Teardown allocation overflows", index) }
                            total = next.partialValue
                        } else if ins.kind != "nop" { break }
                    } else { break }
                }
            }
            if hasBranches && leaf && bodyStart == 1 { leafTotals.append(total) }
            guard end >= bodyStart, regions.last.map({ end > $0.ret }) ?? true else {
                throw failure("cfg_return_shape_not_modeled", "Return regions overlap setup or one another", ret)
            }
            regions.append((end, ret))
        }
        var teardownIndices = Set(regions.flatMap { Array($0.start...$0.ret) })
        var teardownStarts = Set(regions.map(\.start))
        let indexByAddress = Dictionary(uniqueKeysWithValues: instructions.enumerated().map { ($0.element.address, $0.offset) })
        var sharedEdges: [Int: Int] = [:]
        if lastReturn > bodyStart {
            for index in stride(from: lastReturn - 1, through: bodyStart, by: -1) {
                let ins = instructions[index]
                guard ins.kind == "b" || ins.kind == "bcond",
                      let target = indexByAddress[try branchTarget(ins)], target > index,
                      teardownIndices.contains(target),
                      ins.kind != "bcond" || teardownIndices.contains(index + 1) else { continue }
                var start = index
                if index > bodyStart {
                    for prior in stride(from: index - 1, through: bodyStart, by: -1) {
                        guard !teardownIndices.contains(prior) else { break }
                        if leaf ? leafRestore(instructions[prior]) : teardown(instructions[prior]) { start = prior }
                        else if instructions[prior].kind != "nop" { break }
                    }
                }
                guard start < index else { continue }
                sharedEdges[index] = target
                teardownIndices.formUnion(start...index)
                teardownStarts.insert(start)
            }
        }
        if !leafTotals.isEmpty {
            if sharedEdges.isEmpty {
                guard leafTotals.allSatisfy({ $0 == instructions[0].immediate }) else {
                    throw failure("cfg_return_shape_not_modeled", "Every leaf return must deallocate the entry allocation", 0)
                }
            } else {
                var remaining: [Int: (Int64, Int64)] = [:]
                for index in teardownIndices.sorted(by: >) {
                    let ins = instructions[index]
                    if ins.kind == "ret" { remaining[index] = (0, 0); continue }
                    if let target = sharedEdges[index], let next = remaining[target] {
                        if ins.kind == "bcond", let other = remaining[index + 1] {
                            remaining[index] = (min(next.0, other.0), max(next.1, other.1))
                        } else { remaining[index] = next }
                    } else if let next = remaining[index + 1] {
                        let amount = ins.kind == "add" ? ins.immediate : 0
                        let low = next.0.addingReportingOverflow(amount)
                        let high = next.1.addingReportingOverflow(amount)
                        guard !low.overflow, !high.overflow else { throw failure("cfg_return_shape_not_modeled", "Teardown allocation overflows", index) }
                        remaining[index] = (low.partialValue, high.partialValue)
                    } else { throw failure("cfg_return_shape_not_modeled", "Incomplete shared teardown", index) }
                }
                teardownStarts = teardownStarts.filter {
                    remaining[$0].map { $0.0 == instructions[0].immediate && $0.1 == instructions[0].immediate } ?? false
                }
            }
        }
        let body = Set(bodyStart..<lastReturn).subtracting(teardownIndices)
        guard !body.isEmpty else { throw failure("no_supported_observation", "No distinct supported body exists", 0) }
        var targets: [Int: Int] = [:]
        for (index, ins) in instructions.enumerated() {
            if body.contains(index) && (ins.changesSP || ins.changesFP) {
                throw failure("cfg_frame_transition_not_modeled", "Body changes SP or FP", index)
            }
            if ins.kind == "bl" {
                let target = try branchTarget(ins)
                guard body.contains(index), calleeEntries.contains(target), indexByAddress[target] == nil else {
                    throw failure("cfg_call_target_not_modeled", "BL must target a distinct independently known function entry", index)
                }
            }
            if ins.kind == "b" || ins.kind == "bcond" {
                guard let target = indexByAddress[try branchTarget(ins)],
                      body.contains(index) || sharedEdges[index] != nil,
                      sharedEdges[index] == target || body.contains(target) || teardownStarts.contains(target) else {
                    throw failure("cfg_edge_not_modeled", "Branch must target body or a recognized teardown entry", index)
                }
                targets[index] = target
            }
        }
        // Structural graph facts come from the existing engine. Semantic transfer stays here.
        let cfg = CFGBuilder.buildCFG(instructions: try instructions.map { ins in
            let operation: MacIROperation
            if ins.kind == "ret" { operation = .returnValue(nil) }
            else if ins.kind == "b" {
                operation = .intrinsic(destination: nil, name: "branch", arguments: [.immediate(Int64(bitPattern: try branchTarget(ins)))])
            } else if ins.kind == "bcond" {
                operation = .conditionalBranch(condition: ins.addressing, left: .unknown("NZCV"), right: .immediate(0), target: .immediate(Int64(bitPattern: try branchTarget(ins))))
            } else { operation = .intrinsic(destination: nil, name: "unwind_instruction", arguments: []) }
            return MacIRInstruction(source: MacIRSourceSpan(address: ins.address,
                byteText: String(format: "%08x", ins.word), mnemonic: ins.kind, operands: ""), operation: operation)
        })
        guard !cfg.hasUnresolvedTargets else { throw failure("cfg_edge_not_modeled", "CFG contains an unresolved target", 0) }
        let backward = targets.filter { $0.value <= $0.key }
        var loopHeader: Int?
        var loopMembers = Set<Int>()
        if !backward.isEmpty {
            guard backward.count == 1, let edge = backward.first,
                  edge.value < edge.key, instructions[edge.key].kind == "bcond",
                  cfg.irreducibleBlocks.isEmpty,
                  let headerBlock = cfg.blocks.first(where: { $0.instructionRange.contains(edge.value) }),
                  let latchBlock = cfg.blocks.first(where: { $0.instructionRange.contains(edge.key) }),
                  cfg.backEdges.contains(CFGEdge(latchBlock.index, headerBlock.index)) else {
                throw failure("cfg_loop_shape_not_modeled", "Exactly one nonself dominated conditional backedge is supported", backward.keys.sorted().first)
            }
            var members: Set<Int> = [headerBlock.index, latchBlock.index]
            var work = [latchBlock.index]
            while let block = work.popLast() {
                if block == headerBlock.index { continue }
                for predecessor in cfg.blocks[block].predecessors where members.insert(predecessor).inserted { work.append(predecessor) }
            }
            loopMembers = Set(members.flatMap { Array(cfg.blocks[$0].instructionRange) })
            guard loopMembers.isSubset(of: body) else {
                throw failure("cfg_loop_shape_not_modeled", "Natural loop includes setup or teardown", edge.key)
            }
            guard model == .boundedLoopCalls || !loopMembers.contains(where: { instructions[$0].kind == "bl" }) else {
                throw failure("cfg_loop_call_not_modeled", "Calls inside a natural loop are outside this model", edge.value)
            }
            loopHeader = edge.value
        }
        guard limits.maxPaths > 0 else { throw failure("cfg_path_limit", "Initial path exceeds the path budget", 0) }
        struct Path {
            var index: Int
            var state: UnwindAuditMachine
            var certain: Bool
            var calls: Int
            var seen: Set<UnwindAuditSnapshot>
        }
        var queue = [Path(index: 0, state: UnwindAuditMachine(strictCallState: !leaf), certain: true, calls: 0, seen: [])]
        var cursor = 0, created = 1, terminals = 0, steps = 0, visits = 0, closures = 0
        var observations: [UnwindAuditObservation] = []
        while cursor < queue.count {
            var path = queue[cursor]
            cursor += 1
            while true {
                guard instructions.indices.contains(path.index) else { throw failure("cfg_edge_not_modeled", "Path falls outside the function") }
                let ins = instructions[path.index]
                guard steps < limits.maxSteps else { throw failure("cfg_work_limit", "State-visit budget exhausted", path.index) }
                steps += 1
                if path.index == loopHeader {
                    // Under v2 only call occurrence affects future transfer/eligibility.
                    // Keep every machine value and certainty exact; never collapse unknowns.
                    let history = model == .boundedLoopCalls ? min(path.calls, 1) : path.calls
                    let key = path.state.snapshot(certain: path.certain, priorCallCount: history)
                    if path.seen.contains(key) { closures += 1; break }
                    guard path.seen.count < limits.maxPaths else { throw failure("cfg_loop_state_limit", "Distinct header-state budget exhausted", path.index) }
                    path.seen.insert(key)
                    visits += 1
                }
                if leaf && body.contains(path.index) {
                    guard observations.count < limits.maxObservations else { throw failure("observation_limit", "Observation budget exhausted", path.index) }
                    observations.append(UnwindAuditObservation(pc: ins.address, recovered: try recover(path.state, ins.address), certain: path.certain))
                }
                if ins.kind == "ret" {
                    guard path.state.sp == .stack(displacement: 0), (19...30).allSatisfy({ path.state.registers[$0] == .original(register: $0, displacement: 0) }) else {
                        throw failure("unmodeled_return_state", "Return does not restore entry SP and original x19-x30", path.index)
                    }
                    terminals += 1
                    break
                }
                if ins.kind == "b" {
                    guard let target = targets[path.index] else { throw failure("cfg_edge_not_modeled", "Missing branch target", path.index) }
                    path.index = target
                    continue
                }
                if ins.kind == "bcond" {
                    guard let conditionCode = Int(ins.addressing) else { throw failure("cfg_condition_not_modeled", "Condition must be EQ through LE", path.index) }
                    guard let target = targets[path.index] else { throw failure("cfg_edge_not_modeled", "Missing conditional target", path.index) }
                    if let taken = try path.state.condition(conditionCode) {
                        path.index = taken ? target : path.index + 1
                    } else {
                        guard created < limits.maxPaths else { throw failure("cfg_path_limit", "Created-path budget exhausted", path.index) }
                        created += 1
                        var taken = path
                        taken.index = target
                        taken.certain = false
                        queue.append(taken)
                        path.certain = false
                        path.index += 1
                    }
                    continue
                }
                try path.state.apply(ins)
                if ins.kind == "bl" {
                    guard observations.count < limits.maxObservations else { throw failure("observation_limit", "Call observation budget exhausted", path.index) }
                    observations.append(UnwindAuditObservation(pc: ins.address, recovered: try recover(path.state, ins.address), certain: path.certain))
                    path.calls += 1
                    path.state.resumeAfterCall()
                }
                path.index += 1
            }
        }
        guard !observations.isEmpty, terminals > 0 else { throw failure("no_supported_observation", "No supported observation and return path exists", 0) }
        return UnwindAuditExecutionResult(observations: observations, scope: scope, instructionCount: instructions.count,
            steps: steps, loopHeader: loopHeader.map { instructions[$0].address }, loopMemberCount: loopMembers.count,
            loopVisits: visits, loopClosures: closures)
    }

    private static func setup(_ ins: UnwindAuditInstruction) -> Bool {
        (ins.kind == "sub" && ins.rd == 31 && ins.rn == 31)
        || (ins.kind == "add" && ins.rd == 29 && ins.rn == 31)
        || (ins.kind == "stp" && (ins.addressing == "offset" || (ins.addressing == "pre" && ins.immediate < 0)))
    }

    private static func teardown(_ ins: UnwindAuditInstruction) -> Bool {
        ins.kind == "ldp" || (ins.kind == "add" && ins.rd == 31 && (ins.rn == 29 || ins.rn == 31))
        || (ins.kind == "mov" && (19...30).contains(ins.rd))
    }

    private static func leafRestore(_ ins: UnwindAuditInstruction) -> Bool {
        ins.kind == "add" && ins.rd == 31 && ins.rn == 31 && ins.immediate > 0
    }

    private static func branchTarget(_ ins: UnwindAuditInstruction) throws -> UInt64 {
        let result = ins.immediate >= 0 ? ins.address.addingReportingOverflow(UInt64(ins.immediate))
            : ins.address.subtractingReportingOverflow(ins.immediate.magnitude)
        guard !result.overflow else {
            throw UnwindAuditModelError(code: "cfg_edge_not_modeled", message: "Branch target overflows its address space", address: ins.address)
        }
        return result.partialValue
    }
}

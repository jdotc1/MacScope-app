import Foundation

/// Immutable typed-control authority plus the bounded selector/current-cell
/// bridge. This is NOT original table-byte or original jump-table provenance.
/// Production callers first establish RegionalPhysicalStatePlan's unchanged
/// canonicalEvidence and parsed-row contracts for EVERY original instruction.
/// No replay, text rendering, or source-address/name whitelist is an authority.
struct RegionalTypedSwitchPlan {
    struct Case: Equatable {
        let value: Int64
        let target: MacIRValue
        let targetBlock: Int
        let exitOrdinal: Int
    }

    let row: Int
    let block: Int
    let originalOperation: MacIROperation
    let selector: MacIRValue
    let selectorRegister: RegionalBoundaryPlan.Register
    let definitionRow: Int
    let guardRow: Int
    let cases: [Case]
    let defaultTarget: MacIRValue
    let defaultBlock: Int
    let defaultExitOrdinal: Int
    let successors: [Int]
    private let originalFunction: MacIRFunction
    private let originalCFG: CFG

    func matches(function: MacIRFunction) -> Bool { function == originalFunction }
    func matches(function: MacIRFunction, cfg: CFG) -> Bool {
        matches(function: function) && Self.sameCFG(cfg, originalCFG)
    }

    /// nil means an unknown write set, call clobber, or unsupported source row.
    /// Register indices are physical: writing Wn and writing Xn both report n.
    /// The selector definition, immediate CMP, and HI guard occupy one complete
    /// guard block. Its fallthrough dispatch block has that sole predecessor.
    /// Consequently every dispatch visit, including loop revisits, reexecutes
    /// the definition and guard; source order alone is never dominance proof.
    static func prove(function: MacIRFunction, cfg: CFG,
        selectorReads: [Int: RegionalPhysicalStatePlan.TypedSelectorRead] = [:],
        knownRegisterWrites: (Int) -> Set<Int>?) -> [Int: Self]? {
        let instructions = function.instructions
        guard !cfg.hasUnresolvedTargets, cfg.irreducibleBlocks.isEmpty else { return nil }
        var byAddress: [UInt64: Int] = [:]
        for (index, block) in cfg.blocks.enumerated() {
            guard block.index == index, instructions.indices.contains(block.startIndex),
                  block.endIndex > block.startIndex, block.endIndex <= instructions.count,
                  cfg.blockByStartIndex[block.startIndex] == index,
                  byAddress.updateValue(index, forKey: instructions[block.startIndex].source.address) == nil else {
                return nil
            }
        }
        var result: [Int: Self] = [:]
        for (row, instruction) in instructions.enumerated() {
            guard case let .switchDispatch(selector, typedCases, optionalDefault) = instruction.operation else { continue }
            guard case let .register(name, version) = selector, version > 0,
                  let register = RegionalBoundaryPlan.Register(name), register.width == 32, !register.isZero,
                  !typedCases.isEmpty,
                  // Bound certificate/emitter work, not a corpus/function shape.
                  typedCases.count <= 512,
                  typedCases.enumerated().allSatisfy({ $0.element.value == Int64($0.offset) }),
                  let defaultTarget = optionalDefault, let defaultAddress = address(defaultTarget),
                  let defaultBlock = byAddress[defaultAddress],
                  instruction.source.mnemonic == "br",
                  let targetRegister = RegionalBoundaryPlan.Register(instruction.source.operands),
                  targetRegister.width == 64, !targetRegister.isZero,
                  targetRegister.index != register.index,
                  instruction.memoryAccess == nil, plainInstruction(instruction),
                  sourceEnvelopeAgrees(instruction.source) else { return nil }

            let owners = cfg.blocks.filter { $0.instructionRange.contains(row) }
            guard owners.count == 1, let dispatch = owners.first,
                  dispatch.endIndex == row + 1, dispatch.predecessors.count == 1,
                  let guardIndex = dispatch.predecessors.first,
                  cfg.blocks.indices.contains(guardIndex) else { return nil }
            let guardBlock = cfg.blocks[guardIndex]
            let definitionRow = guardBlock.startIndex
            let compareRow = definitionRow + 1
            let guardRow = definitionRow + 2
            guard guardBlock.endIndex == definitionRow + 3,
                  guardBlock.endIndex == dispatch.startIndex,
                  guardBlock.successors == [defaultBlock, dispatch.index],
                  defaultBlock != dispatch.index,
                  instructions.indices.contains(guardRow),
                  instructions.indices.filter({ definitions(instructions[$0].operation).contains(selector) }) == [definitionRow],
                  knownRegisterWrites(definitionRow) == Set([register.index]) else { return nil }

            let definition = instructions[definitionRow]
            let definitionOperands = MacIRBuilder.splitOperands(definition.source.operands)
            guard definition.source.mnemonic == "sub", definitionOperands.count == 3,
                  definitionOperands[0] == name, definitionOperands[1] == name,
                  let bias = MacIRBuilder.parseImmediate(definitionOperands[2]),
                  case let .binary(destination, "-", input, right) = definition.operation,
                  destination == selector,
                  (isWidth32Read(input, index: register.index) ||
                   selectorReads[definitionRow]?.accepts(function: function, cfg: cfg,
                       row: definitionRow, operand: input, register: register) == true),
                  input != selector,
                  right == .immediate(bias), definition.memoryAccess == nil else { return nil }

            let bound = Int64(typedCases.count - 1)
            let comparison = instructions[compareRow]
            let comparisonOperands = MacIRBuilder.splitOperands(comparison.source.operands)
            guard comparison.source.mnemonic == "cmp", comparisonOperands.count == 2,
                  comparisonOperands[0] == name, MacIRBuilder.parseImmediate(comparisonOperands[1]) == bound,
                  comparison.operation == .intrinsic(destination: nil, name: "compare", arguments: [selector, .immediate(bound)]),
                  comparison.memoryAccess == nil else { return nil }
            let branch = instructions[guardRow]
            guard branch.source.mnemonic == "b.hi", target(branch.source.operands) == defaultAddress,
                  branch.operation == .conditionalBranch(condition: ">",
                    left: .unary(op: "(uint32_t)", value: selector),
                    right: .unary(op: "(uint32_t)", value: .immediate(bound)), target: defaultTarget),
                  branch.memoryAccess == nil else { return nil }

            // Exact source/envelope and old typed atom agreement is checked in
            // addition to caller-owned canonical decoded-byte evidence. Every
            // setup row has a known write set and cannot branch, call or clobber.
            for index in definitionRow...row {
                let current = instructions[index]
                guard plainInstruction(current), sourceEnvelopeAgrees(current.source),
                      index == definitionRow || instructions[index - 1].source.address.isContiguous(to: current.source.address),
                      let writes = knownRegisterWrites(index),
                      index == definitionRow || !writes.contains(register.index) else { return nil }
                if dispatch.instructionRange.contains(index), index != row {
                    switch current.operation {
                    case .call, .unknown, .conditionalBranch, .returnValue, .switchDispatch:
                        return nil
                    case let .intrinsic(_, name, _) where name == "branch":
                        return nil
                    default: break
                    }
                }
            }

            var successors: [Int] = []
            var cases: [Case] = []
            for item in typedCases {
                guard let targetAddress = address(item.target), let targetBlock = byAddress[targetAddress] else { return nil }
                if !successors.contains(targetBlock) { successors.append(targetBlock) }
                guard let ordinal = successors.firstIndex(of: targetBlock) else { return nil }
                cases.append(Case(value: item.value, target: item.target, targetBlock: targetBlock, exitOrdinal: ordinal))
            }
            if !successors.contains(defaultBlock) { successors.append(defaultBlock) }
            guard successors == dispatch.successors,
                  let defaultOrdinal = successors.firstIndex(of: defaultBlock) else { return nil }
            result[row] = Self(row: row, block: dispatch.index, originalOperation: instruction.operation,
                selector: selector, selectorRegister: register, definitionRow: definitionRow, guardRow: guardRow,
                cases: cases, defaultTarget: defaultTarget, defaultBlock: defaultBlock,
                defaultExitOrdinal: defaultOrdinal, successors: successors,
                originalFunction: function, originalCFG: cfg)
        }
        return result
    }

    /// This deliberately projects supplied typed cases into Builder INPUT only.
    /// Builder's entire OUTPUT is compared by producerCorrespondence; no source,
    /// operation, case, default, call, return, declaration or sidecar is erased.
    /// These arrays are not recovered raw table data and establish no dynamic
    /// selector fact. In particular, a changed case mapping with identical
    /// distinct CFG edges invalidates an existing certificate through matches.
    static func modelRelativeJumpTables(function: MacIRFunction,
        plans: [Int: Self]) -> [UInt64: [UInt64]]? {
        let switchRows = Set(function.instructions.indices.filter {
            if case .switchDispatch = function.instructions[$0].operation { return true }; return false
        })
        guard switchRows == Set(plans.keys) else { return nil }
        var result: [UInt64: [UInt64]] = [:]
        for row in switchRows {
            guard let plan = plans[row], plan.row == row, plan.matches(function: function),
                  plan.originalOperation == function.instructions[row].operation else { return nil }
            let targets = plan.cases.compactMap { address($0.target) }
            guard targets.count == plan.cases.count,
                  result.updateValue(targets, forKey: function.instructions[row].source.address) == nil else { return nil }
        }
        return result
    }

    private static func address(_ value: MacIRValue) -> UInt64? {
        guard case let .immediate(value) = value, value >= 0 else { return nil }
        return UInt64(value)
    }
    private static func target(_ text: String) -> UInt64? {
        text.hasPrefix("0x") ? UInt64(text.dropFirst(2), radix: 16) : UInt64(text)
    }
    private static func isWidth32Read(_ value: MacIRValue, index: Int) -> Bool {
        switch value {
        case let .register(name, version):
            guard let register = RegionalBoundaryPlan.Register(name) else { return false }
            return version >= 0 && register.index == index && register.width == 32
        case let .unary("(uint32_t)", .register(name, version)):
            guard let register = RegionalBoundaryPlan.Register(name) else { return false }
            return version >= 0 && register.index == index && [32, 64].contains(register.width)
        default: return false
        }
    }
    private static func definitions(_ operation: MacIROperation) -> [MacIRValue] {
        switch operation {
        case let .assign(destination, _), let .binary(destination, _, _, _),
             let .load(destination, _), let .select(destination, _, _, _, _, _),
             let .compareToBool(destination, _, _, _), let .stackSlotRead(destination, _, _):
            return [destination]
        case let .loadWriteback(destination, baseDestination, _, _, _): return [destination, baseDestination]
        case let .storeWriteback(_, baseDestination, _, _, _): return [baseDestination]
        case let .stackSlotPairRead(first, _, _, second, _, _): return [first, second]
        case let .call(_, destination), let .intrinsic(destination, _, _), let .unknown(destination, _, _, _):
            return destination.map { [$0] } ?? []
        default: return []
        }
    }
    private static func plainInstruction(_ instruction: MacIRInstruction) -> Bool {
        instruction.returnTarget == nil && instruction == MacIRInstruction(source: instruction.source,
            operation: instruction.operation, memoryAccess: instruction.memoryAccess, returnTarget: nil)
    }
    private static func sourceEnvelopeAgrees(_ source: MacIRSourceSpan) -> Bool {
        guard let envelope = source.structuredOperands else { return false }
        switch envelope.coverage {
        case .complete: return envelope.rendersExactly(mnemonic: source.mnemonic, operands: source.operands)
        case .unavailable:
            // canonicalEvidence separately proves the real decoder supplied
            // this same unavailable envelope for these exact bytes. Absence or
            // partial/contradictory metadata is never treated as this witness.
            return envelope == .unavailable(mnemonic: source.mnemonic, operands: source.operands)
        case .partial: return false
        }
    }
    private static func sameCFG(_ left: CFG, _ right: CFG) -> Bool {
        left.blocks == right.blocks && left.entryIndex == right.entryIndex &&
        left.domTree == right.domTree && left.postDomTree == right.postDomTree &&
        left.loopHeaders == right.loopHeaders && left.backEdges == right.backEdges &&
        left.irreducibleBlocks == right.irreducibleBlocks &&
        left.blockByStartIndex == right.blockByStartIndex && left.hasUnresolvedTargets == right.hasUnresolvedTargets
    }
}

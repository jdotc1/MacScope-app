import Foundation

/// The first rejecting guard in the existing NZCV walk, not a text heuristic.
enum CompareElisionReason: Equatable {
    case unknownOperand, memoryOperand, ccmp, unknownReader
    case dirtyUnknownOp, dirtyExactValue, dirtyPrintedName, phiClobber
    case nonFlagIndependentIntrinsic(String)
    case unresolvedInteriorEdge, switchWithoutDefault
    case notRestated(String)
    case noReader, loopStaleVersion

    var key: String {
        switch self {
        case .unknownOperand: return "unknownOperand"
        case .memoryOperand: return "memoryOperand"
        case .ccmp: return "ccmp"
        case .unknownReader: return "unknownReader"
        case .dirtyUnknownOp: return "dirtyUnknownOp"
        case .dirtyExactValue: return "dirtyExactValue"
        case .dirtyPrintedName: return "dirtyPrintedName"
        case .phiClobber: return "phiClobber"
        case .nonFlagIndependentIntrinsic: return "nonFlagIndependentIntrinsic"
        case .unresolvedInteriorEdge: return "unresolvedInteriorEdge"
        case .switchWithoutDefault: return "switchWithoutDefault"
        case .notRestated: return "notRestated"
        case .noReader: return "noReader"
        case .loopStaleVersion: return "loopStaleVersion"
        }
    }
}

struct CompareElisionRejection: Equatable {
    let reason: CompareElisionReason
    let address: UInt64
    let detail: String
}

enum CompareElisionDecision: Equatable {
    case elide
    case keep(CompareElisionRejection)
}

extension PseudocodePrinter {
    /// Materialize an equality predicate only in the presentation copy. The
    /// original intrinsic and its persisted NZCV binding remain authoritative.
    /// Relational predicates require flag-kind facts not retained by `compare`.
    static func ssaComparisonPresentation(of function: MacIRFunction) -> MacIRFunction {
        guard function.ssaEnabled, let info = function.ssaInfo else { return function }
        var sourceRows: [UInt64: [Int]] = [:]
        var instructionRows: [UInt64: [Int]] = [:]
        for (row, address) in info.sourceAddresses.enumerated() {
            sourceRows[address, default: []].append(row)
        }
        for (row, instruction) in function.instructions.enumerated() {
            instructionRows[instruction.source.address, default: []].append(row)
        }
        var argumentWidths: [MacIRParameterBindingID: Set<Int>] = [:]
        for parameter in function.parameters {
            guard let binding = parameter.bindingID,
                  case let .gpr(_, width) = parameter.abiLocation else { continue }
            argumentWidths[binding, default: []].insert(width)
        }
        func width(of value: MacIRValue) -> Int? {
            switch value {
            case let .register(name, _):
                return MacIRBuilder.integerRegisterView(name)?.width
            case let .argument(binding):
                guard let widths = argumentWidths[binding], widths.count == 1 else { return nil }
                return widths.first
            case let .unary(op, _):
                switch op {
                case "(uint32_t)", "(int32_t)": return 32
                case "(uint64_t)", "(int64_t)": return 64
                default: return nil
                }
            default:
                return nil
            }
        }
        func stable(_ value: MacIRValue) -> Bool {
            switch value {
            case .register, .argument, .temporary, .immediate:
                return true
            case let .unary(op, inner):
                return op != "*" && stable(inner)
            case let .binaryExpression(_, left, right):
                return stable(left) && stable(right)
            case let .bitTest(inner, _):
                return stable(inner)
            default:
                return false
            }
        }
        func hasWidthOrIsImmediate(_ value: MacIRValue, width: Int?) -> Bool {
            if width != nil { return true }
            if case .immediate = value { return true }
            return false
        }
        var presentation = function
        for (index, instruction) in function.instructions.enumerated() {
            guard case let .intrinsic(nil, name, targets) = instruction.operation,
                  name == "branch_eq" || name == "branch_ne", targets.count == 1,
                  case .immediate = targets[0],
                  let condition = MacIRBuilder.branchCondition(for: String(name.dropFirst("branch_".count))),
                  instructionRows[instruction.source.address]?.count == 1,
                  let branchRows = sourceRows[instruction.source.address], branchRows.count == 1,
                  let branchRow = branchRows.first, info.plan.rowReadBindings.indices.contains(branchRow),
                  let read = info.plan.rowReadBindings[branchRow][96] else { continue }
            let definitionID = info.plan.canonicalID(read)
            guard info.plan.definitions.indices.contains(definitionID) else { continue }
            let definition = info.plan.definitions[definitionID]
            guard definition.cell == 96, definition.view == .flags, definition.bitWidth == 4,
                  case let .instruction(address) = definition.origin,
                  let producerRows = sourceRows[address], producerRows.count == 1,
                  let producerRow = producerRows.first,
                  info.plan.rowWriteBindings.indices.contains(producerRow),
                  let write = info.plan.rowWriteBindings[producerRow][96],
                  info.plan.canonicalID(write) == definitionID,
                  let producers = instructionRows[address], producers.count == 1,
                  let producerIndex = producers.first,
                  case let .intrinsic(nil, "compare", operands) = function.instructions[producerIndex].operation,
                  operands.count == 2, operands.allSatisfy(stable) else { continue }
            let leftWidth = width(of: operands[0])
            let rightWidth = width(of: operands[1])
            guard let operandWidth = leftWidth ?? rightWidth, operandWidth == 32 || operandWidth == 64,
                  leftWidth == nil || leftWidth == operandWidth,
                  rightWidth == nil || rightWidth == operandWidth else { continue }
            // An untyped constant takes the other operand's comparison width;
            // every nonconstant operand must carry an exact view or cast.
            guard hasWidthOrIsImmediate(operands[0], width: leftWidth),
                  hasWidthOrIsImmediate(operands[1], width: rightWidth) else { continue }
            presentation.instructions[index].operation = .conditionalBranch(
                condition: condition, left: operands[0], right: operands[1], target: targets[0])
        }
        return presentation
    }

    /// Additional suppression for ordinary statement emission. Existing region and
    /// adjacent-cset folds still see the original IR and keep their matcher order.
    /// NZCV has no SSA value in MacIR: follow its reaching definition along each
    /// control-flow edge, with a separate dirty state for operand storage.
    func redundantCompareIndices(function: MacIRFunction, names: PseudocodeNameContext) -> Set<Int> {
        var result = Set(compareElisionDecision(function: function, names: names).compactMap { index, decision in
            decision == .elide ? index : nil
        })
        if !function.ssaElidedChainRows.isEmpty {
            // A28: the whole cmp;ccmp chain was consumed by lifted conditions.
            for (index, row) in function.instructions.enumerated()
            where function.ssaElidedChainRows.contains(row.source.address) {
                if case let .intrinsic(_, name, _) = row.operation,
                   name == "compare" || name.hasPrefix("conditional_compare_") {
                    result.insert(index)
                }
            }
        }
        return result
    }

    /// Decisions for all well-formed compare candidates, keyed by instruction index.
    /// Share the function context once, just as the original suppression pass did.
    /// The diagnostic payload never participates in traversal/visited identity.
    func compareElisionDecision(function: MacIRFunction, names: PseudocodeNameContext) -> [Int: CompareElisionDecision] {
        let rows = function.instructions
        guard !rows.isEmpty else { return [:] }
        let phisByAddress = Dictionary(grouping: function.phis, by: \.blockAddress)
        let addressIndices = Dictionary(rows.enumerated().map { ($0.element.source.address, $0.offset) },
                                        uniquingKeysWith: min)
        guard let firstAddress = rows.map(\.source.address).min(),
              let lastAddress = rows.map(\.source.address).max() else { return [:] }
        let widthGroups = Dictionary(grouping: function.parameters.compactMap { parameter in
            parameter.bindingID.map { ($0, parameter.abiLocation) }
        }, by: \.0)
        let widths: [MacIRParameterBindingID: Int] = widthGroups.compactMapValues { entries in
            guard entries.count == 1 else { return nil }
            switch entries[0].1 {
            case let .gpr(_, width), let .simd(_, width): return width
            case let .entryStack(_, size, _): return size * 8
            case .unbound: return nil
            }
        }
        func leaves(_ value: MacIRValue) -> [MacIRValue] {
            switch value {
            case let .signedBitfield(node): return leaves(node.source)
            case let .unary(_, inner), let .bitTest(inner, _): return leaves(inner)
            case let .binaryExpression(_, left, right): return leaves(left) + leaves(right)
            case let .abiComposite(_, fragments): return fragments.flatMap(leaves)
            default: return [value]
            }
        }
        // Builder pair writeback layout: data0, data1, oldBase, newBase,
        // signed delta, pre-index bit. Admit only the complete modeled shape.
        func validPairWriteback(_ destination: MacIRValue?, _ name: String, _ arguments: [MacIRValue]) -> Bool {
            guard destination == nil, arguments.count == 6,
                  case .register(name: "sp", version: _) = arguments[2],
                  case .register(name: "sp", version: _) = arguments[3],
                  case .immediate = arguments[4],
                  case let .immediate(preIndex) = arguments[5],
                  preIndex == 0 || preIndex == 1 else { return false }
            if name == "restore_pair_writeback" {
                guard case .register = arguments[0], case .register = arguments[1] else { return false }
            }
            return true
        }
        func definitions(_ operation: MacIROperation) -> [MacIRValue] {
            switch operation {
            case let .assign(d, _), let .binary(d, _, _, _), let .load(d, _),
                 let .stackSlotRead(d, _, _), let .select(d, _, _, _, _, _),
                 let .compareToBool(d, _, _, _): return [d]
            case let .loadWriteback(d, base, _, _, _): return [d, base]
            case let .storeWriteback(_, base, _, _, _): return [base]
            case let .stackSlotPairRead(a, _, _, b, _, _): return [a, b]
            case let .store(_, address): return [address]
            case let .intrinsic(d, name, arguments):
                if ["paciasp", "pacibsp", "autiasp", "autibsp", "xpaclri"].contains(name) {
                    return [.register(name: "x30", version: 0)]
                }
                if name == "restore_pair" { return Array(arguments.prefix(2)) }
                if name == "save_pair" { return Array(arguments.dropFirst(2)) }
                if name == "restore_pair_writeback", arguments.count == 6 {
                    return [arguments[0], arguments[1], arguments[3]]
                }
                if name == "save_pair_writeback", arguments.count == 6 { return [arguments[3]] }
                return d.map { [$0] } ?? []
            case let .unknown(d, _, _, _), let .call(_, d): return d.map { [$0] } ?? []
            default: return []
            }
        }
        // These intrinsics have no flag input. Other opaque intrinsics cannot
        // prove that all flag readers restate the comparison.
        let flagIndependentIntrinsics: Set<String> = [
            "nop", "adrp", "save_pair", "restore_pair", "stack_alloc", "stack_free", "fmov",
            "paciasp", "pacibsp", "autiasp", "autibsp", "xpaclri", "bti",
            // MacIRBuilder scalar division reads only its two register inputs.
            "a64_udiv32", "a64_sdiv32", "a64_udiv64", "a64_sdiv64",
            "restore_pair_writeback", "save_pair_writeback",
            // Explicit destination-only NEON contracts from VectorLanes/VectorLogical.
            // Saturating (FPSR.QC), memory, and unaudited forms stay opaque.
            "neon_abs_8h",
            "neon_add_4h_zero_high64",
            "neon_add_4s",
            "neon_add_8h",
            "neon_and_8b_zero_upper",
            "neon_cmeqz_8h",
            "neon_cmltz_8h",
            "neon_dup_4h_zero_high64",
            "neon_dup_4s",
            "neon_dup_8b_zero_high64",
            "neon_dup_8h",
            "neon_eor_16b_zero_upper",
            "neon_eor_8b_zero_upper",
            "neon_mla_4s",
            "neon_mla_8h",
            "neon_mul_4h_zero_high64",
            "neon_mul_4s",
            "neon_neg_8h",
            "neon_not_16b",
            "neon_orr_16b_zero_upper",
            "neon_orr_8b_zero_upper",
            "neon_rshrn2_16b_from_8h_shift2_keep_low64",
            "neon_rshrn2_16b_from_8h_shift4_keep_low64",
            "neon_rshrn2_8h_from_4s_shift11_keep_low64",
            "neon_rshrn2_8h_from_4s_shift15_keep_low64",
            "neon_rshrn2_8h_from_4s_shift2_keep_low64",
            "neon_rshrn_4h_from_4s_shift11_zero_high64",
            "neon_rshrn_4h_from_4s_shift15_zero_high64",
            "neon_rshrn_4h_from_4s_shift2_zero_high64",
            "neon_rshrn_8b_from_8h_shift2_zero_high64",
            "neon_rshrn_8b_from_8h_shift4_zero_high64",
            "neon_saddl2_4s_from_8h",
            "neon_saddl_4s_from_4h",
            "neon_saddw_4s_from_4s_4h",
            "neon_shl_4h_shift2_zero_high64",
            "neon_shl_8h_shift2",
            "neon_shrn2_16b_from_8h_shift2_keep_low64",
            "neon_shrn2_16b_from_8h_shift4_keep_low64",
            "neon_shrn2_8h_from_4s_shift15_keep_low64",
            "neon_shrn_4h_from_4s_shift15_zero_high64",
            "neon_shrn_8b_from_8h_shift1_zero_high64",
            "neon_shrn_8b_from_8h_shift2_zero_high64",
            "neon_shrn_8b_from_8h_shift4_zero_high64",
            "neon_smlal2_4s_from_8h_by_lane0",
            "neon_smlal2_4s_from_8h_by_lane1",
            "neon_smlal2_4s_from_8h_by_lane2",
            "neon_smlal2_4s_from_8h_by_lane3",
            "neon_smlal_4s_from_4h_by_lane0",
            "neon_smlal_4s_from_4h_by_lane1",
            "neon_smlal_4s_from_4h_by_lane2",
            "neon_smlal_4s_from_4h_by_lane3",
            "neon_smlsl2_4s_from_8h",
            "neon_smlsl_4s_from_4h",
            "neon_smlsl_4s_from_4h_by_lane0",
            "neon_smlsl_4s_from_4h_by_lane1",
            "neon_smlsl_4s_from_4h_by_lane2",
            "neon_smull2_4s_from_8h",
            "neon_smull2_4s_from_8h_by_lane0",
            "neon_smull2_4s_from_8h_by_lane1",
            "neon_smull2_4s_from_8h_by_lane2",
            "neon_smull2_4s_from_8h_by_lane3",
            "neon_smull_4s_from_4h",
            "neon_smull_4s_from_4h_by_lane0",
            "neon_smull_4s_from_4h_by_lane1",
            "neon_smull_4s_from_4h_by_lane2",
            "neon_smull_4s_from_4h_by_lane3",
            "neon_srshr_8h_shift2",
            "neon_sshll2_2d_from_4s_shift0",
            "neon_sshll_2d_from_2s_shift0",
            "neon_sshll_4s_from_4h_shift13",
            "neon_ssubl2_4s_from_8h",
            "neon_ssubl_4s_from_4h",
            "neon_sub_4h_zero_high64",
            "neon_sub_4s",
            "neon_sub_8h",
            "neon_trn1_4s",
            "neon_trn1_8h",
            "neon_trn2_4s",
            "neon_trn2_8h",
            "neon_uaddw2_8h_from_8h_16b",
            "neon_uaddw_8h_from_8h_8b",
            "neon_umlal2_4s_from_8h",
            "neon_umlal2_8h_from_16b",
            "neon_umlal_4s_from_4h",
            "neon_umlsl2_4s_from_8h",
            "neon_umlsl_4s_from_4h",
            "neon_umull2_4s_from_8h",
            "neon_umull2_8h_from_16b",
            "neon_umull_4s_from_4h",
            "neon_umull_8h_from_8b",
            "neon_ushl_8h",
            "neon_ushll2_8h_from_16b_shift0",
            "neon_ushll_8h_from_8b_shift0",
            "neon_uzp1_16b",
            "neon_uzp1_8b_zero_high64",
            "neon_uzp1_8h",
            "neon_uzp2_8h",
            "neon_zip1_16b",
            "neon_zip1_4s",
            "neon_zip1_8b_zero_high64",
            "neon_zip2_4s",
            "neon_zip2_8b_zero_high64"
        ]
        // These new admissions require producer types and source agreement, not a name whitelist.
        func typedIndependentIntrinsic(_ row: MacIRInstruction) -> Bool {
            guard case let .intrinsic(destination?, name, arguments) = row.operation,
                  row.memoryAccess == nil, row.scalarFP == nil, row.fpEnvironment == nil,
                  row.returnTarget == nil,
                  case let .register(destinationName, version) = destination, version > 0 else { return false }
            if name == "neon_integer_constant" {
                guard arguments.isEmpty, let metadata = row.neonImmediate,
                      let decoded = MacIRBuilder.neonMoveImmediate(mnemonic: row.source.mnemonic,
                                                                  operandText: row.source.operands),
                      decoded.destination == destinationName, decoded.semantics == metadata else { return false }
                return true
            }
            guard row.neonImmediate == nil, row.source.mnemonic == name else { return false }
            let sourceRegisters = MacIRBuilder.splitOperands(row.source.operands)
            func registerWidth(_ name: String) -> Int? {
                guard let prefix = name.first, prefix == "x" || prefix == "w",
                      let number = Int(name.dropFirst()), (0...30).contains(number),
                      name == "\(prefix)\(number)" else { return nil }
                return prefix == "x" ? 64 : 32
            }
            guard let width = registerWidth(destinationName), sourceRegisters.first == destinationName,
                  sourceRegisters.count == arguments.count + 1 else { return false }
            for (argument, sourceRegister) in zip(arguments, sourceRegisters.dropFirst()) {
                guard case let .register(name, _) = argument, name == sourceRegister,
                      registerWidth(name) == width else { return false }
            }
            if ["clz", "rbit", "rev", "rev16"].contains(name) { return arguments.count == 1 }
            return name == "smulh" && width == 64 && arguments.count == 2
        }
        func physicalRegister(_ value: MacIRValue) -> String? {
            switch value {
            case let .register(name, _):
                if name == "sp" || name == "wsp" { return "sp" }
                guard let prefix = name.first, let number = Int(name.dropFirst()) else { return nil }
                if (prefix == "x" || prefix == "w"), (0...30).contains(number) { return "x\(number)" }
                if ["v", "q", "d", "s", "h", "b"].contains(String(prefix)), (0...31).contains(number) {
                    return "v\(number)"
                }
                return nil
            case let .argument(binding):
                switch binding.kind {
                case .gpr: return "x\(binding.value)"
                case .simd: return "v\(binding.value)"
                case .entryStack: return nil
                }
            default: return nil
            }
        }
        // A cyclic strongly connected component is exactly a region in which a path
        // can re-enter a block. Cut fresh NZCV definitions and ABI boundaries first:
        // a loop through the original compare does not carry its old flags around.
        // Every reader reachable from a cyclic component can be reached *after* a
        // back edge. This formulation handles joins without exponential path sets.
        var edges = Array(repeating: [Int](), count: rows.count)
        for (index, row) in rows.enumerated() {
            if MacIRBuilder.writesNZCVFlags(row.source.mnemonic) { continue }
            var targets: [MacIRValue] = []
            var fallsThrough = true
            switch row.operation {
            case .intrinsic(_, "compare", _), .call, .returnValue: continue
            case let .conditionalBranch(_, _, _, target): targets = [target]
            case let .intrinsic(_, "branch", arguments): targets = arguments; fallsThrough = false
            case let .switchDispatch(_, cases, defaultTarget):
                targets = cases.map(\.target) + (defaultTarget.map { [$0] } ?? [])
                fallsThrough = false
            default: break
            }
            edges[index] = targets.compactMap {
                guard case let .immediate(address) = $0 else { return nil }
                return addressIndices[UInt64(bitPattern: address)]
            }
            if fallsThrough, rows.indices.contains(index + 1) { edges[index].append(index + 1) }
        }
        var serial = 0
        var discovery = Array(repeating: -1, count: rows.count)
        var low = discovery
        var stack: [Int] = []
        var onStack: Set<Int> = []
        var loopWrites: [Int: Set<String>] = [:]
        func visit(_ index: Int) {
            discovery[index] = serial; low[index] = serial; serial += 1
            stack.append(index); onStack.insert(index)
            var frames: [(index: Int, nextEdge: Int)] = [(index, 0)]
            while let frame = frames.last {
                let index = frame.index
                if frame.nextEdge < edges[index].count {
                    let next = edges[index][frame.nextEdge]
                    frames[frames.count - 1].nextEdge += 1
                    if discovery[next] == -1 {
                        discovery[next] = serial; low[next] = serial; serial += 1
                        stack.append(next); onStack.insert(next)
                        frames.append((next, 0))
                    } else if onStack.contains(next) {
                        low[index] = min(low[index], discovery[next])
                    }
                    continue
                }
                frames.removeLast()
                if low[index] == discovery[index] {
                    var component: [Int] = []
                    while let member = stack.popLast() {
                        onStack.remove(member); component.append(member)
                        if member == index { break }
                    }
                    if component.count > 1 || edges[index].contains(index) {
                        let writes = Set(component.flatMap { member -> [String] in
                            let row = rows[member]
                            // Store addresses are memory definitions, not physical-register writes.
                            let defs: [MacIRValue]
                            if case .store = row.operation { defs = [] } else { defs = definitions(row.operation) }
                            return (defs + (phisByAddress[row.source.address] ?? []).map(\.destination))
                                .compactMap(physicalRegister)
                        })
                        for member in component { loopWrites[member] = writes }
                    }
                }
                if let parent = frames.last {
                    low[parent.index] = min(low[parent.index], low[index])
                }
            }
        }
        for index in rows.indices where discovery[index] == -1 { visit(index) }
        struct State: Hashable { var index: Int; var dirty: Bool; var loopStale: Bool = false }

        struct Pending {
            var state: State
            var cause: CompareElisionRejection?
        }
        var result: [Int: CompareElisionDecision] = [:]
        for (compareIndex, compare) in rows.enumerated() {
            guard case let .intrinsic(nil, "compare", operands) = compare.operation,
                  operands.count == 2 else { continue }
            let operandLeaves = operands.flatMap(leaves)
            guard !operandLeaves.contains(where: {
                switch $0 { case .unknown, .argumentFragment: return true; default: return false }
            }) else {
                result[compareIndex] = .keep(.init(reason: .unknownOperand, address: compare.source.address,
                    detail: "operand leaves: \(operandLeaves)"))
                continue
            }
            func readsMemory(_ value: MacIRValue) -> Bool {
                switch value {
                case .stackSlot: return true
                case let .signedBitfield(node): return readsMemory(node.source)
                case let .unary(op, inner): return op == "*" || readsMemory(inner)
                case let .binaryExpression(_, a, b): return readsMemory(a) || readsMemory(b)
                case let .bitTest(inner, _): return readsMemory(inner)
                default: return false
                }
            }
            let hasMemoryOperand = operands.contains(where: readsMemory)
            let operandRegisters = Set(operandLeaves.compactMap(physicalRegister))
            let values = Set(operandLeaves)
            let printedNames = Set(operandLeaves.compactMap { value -> String? in
                if case .immediate = value { return nil }
                return valueText(for: value, names: names)
            })
            // Readers restate the original SSA values. A different version of
            // the same register (including an argument's ABI register) is safe
            // unless a display-name override/coalescing makes the names collide.
            func clobberedDefinition(_ definition: MacIRValue) -> CompareElisionReason? {
                if values.contains(definition) { return .dirtyExactValue }
                if printedNames.contains(valueText(for: definition, names: names)) { return .dirtyPrintedName }
                return nil
            }
            func clobberReason(_ operation: MacIROperation) -> CompareElisionReason? {
                if hasMemoryOperand {
                    switch operation {
                    case .store, .storeWriteback, .intrinsic(_, "save_pair", _),
                         .intrinsic(_, "save_pair_writeback", _): return .memoryOperand
                    default: break
                    }
                }
                for definition in definitions(operation) {
                    if let reason = clobberedDefinition(definition) { return reason }
                }
                return nil
            }
            func restates(_ operation: MacIROperation, source: MacIRSourceSpan) -> Bool {
                // CMN carry is addition overflow, not unsigned subtraction from
                // the negated addend. Recognize only the builder's exact carry
                // predicate; the surrounding walk still proves every flag use.
                if function.ssaEnabled, compare.source.mnemonic == "cmn",
                   let register = MacIRBuilder.splitOperands(compare.source.operands).first,
                   let width = MacIRBuilder.scalarDataBitWidth(register),
                   width == 32 || width == 64,
                   case let .conditionalBranch(_, _, _, target) = operation,
                   ["b.lo", "b.cc", "b.hs", "b.cs"].contains(source.mnemonic) {
                    let addend: MacIRValue?
                    let cast = "(uint\(width)_t)"
                    switch operands[1] {
                    case let .immediate(negative):
                        addend = .immediate(Int64(bitPattern: 0 &- UInt64(bitPattern: negative)))
                    case let .unary("-", value): addend = value
                    case let .unary(outer, .binaryExpression("-",
                        .unary(zeroCast, .immediate(0)), .unary(addendCast, value)))
                        where outer == cast && zeroCast == cast && addendCast == cast:
                        addend = value
                    default: addend = nil
                    }
                    if let addend {
                        func unsigned(_ value: MacIRValue) -> MacIRValue {
                            .unary(op: width == 32 ? "(uint32_t)" : "(uint64_t)", value: value)
                        }
                        let carry = MacIROperation.conditionalBranch(
                            condition: ["b.lo", "b.cc"].contains(source.mnemonic) ? "<=" : ">",
                            left: unsigned(operands[0]),
                            right: unsigned(.unary(op: "~", value: unsigned(addend))), target: target)
                        if operation == carry { return true }
                    }
                }
                let expected: MacIROperation
                switch operation {
                case let .conditionalBranch(condition, _, _, target):
                    expected = .conditionalBranch(condition: condition, left: operands[0], right: operands[1], target: target)
                case let .select(destination, condition, _, _, t, f):
                    expected = .select(destination: destination, condition: condition, left: operands[0], right: operands[1], trueValue: t, falseValue: f)
                case let .compareToBool(destination, condition, _, _):
                    expected = .compareToBool(destination: destination, condition: condition, left: operands[0], right: operands[1])
                default: return false
                }
                let typed = MacIRBuilder.explicitComparisonTypes(expected, source: source,
                    argumentBitWidths: widths, parameters: function.parameters,
                    projectSigned: function.ssaEnabled)
                if operation == typed { return true }
                // Only the positive int-representable immediate's uint32 conversion
                // may be absent. The explicit left cast fixes the C comparison type.
                guard case .unary("(uint32_t)", _) = operands[0],
                      case let .immediate(immediate) = operands[1],
                      (0...Int64(Int32.max)).contains(immediate), operation == expected else { return false }
                let suffix = source.mnemonic.hasPrefix("b.") ? String(source.mnemonic.dropFirst(2))
                    : MacIRBuilder.splitOperands(source.operands).last ?? ""
                let unsignedOperators = ["hi": ">", "ls": "<=", "lo": "<", "cc": "<", "hs": ">=", "cs": ">="]
                let condition: String
                let converted: MacIROperation
                let right = MacIRValue.unary(op: "(uint32_t)", value: operands[1])
                switch operation {
                case let .conditionalBranch(c, left, _, target):
                    condition = c
                    converted = .conditionalBranch(condition: c, left: left, right: right, target: target)
                case let .select(d, c, left, _, t, f):
                    condition = c
                    converted = .select(destination: d, condition: c, left: left, right: right, trueValue: t, falseValue: f)
                case let .compareToBool(d, c, left, _):
                    condition = c
                    converted = .compareToBool(destination: d, condition: c, left: left, right: right)
                default: return false
                }
                return unsignedOperators[suffix] == condition && converted == typed
            }
            var pending = [Pending(state: State(index: compareIndex + 1, dirty: false), cause: nil)]
            var visited: Set<State> = []
            var sawReader = false
            var rejection: CompareElisionRejection?
            func reject(_ reason: CompareElisionReason, _ row: MacIRInstruction, _ detail: String = "") {
                if rejection == nil {
                    rejection = .init(reason: reason, address: row.source.address,
                        detail: "\(row.source.mnemonic) \(row.source.operands); \(row.operation); \(detail)")
                }
            }
            while let entry = pending.popLast(), rejection == nil {
                var state = entry.state
                guard rows.indices.contains(state.index) else { continue }
                if let writes = loopWrites[state.index], !writes.isDisjoint(with: operandRegisters) {
                    state.loopStale = true
                }
                guard visited.insert(state).inserted else { continue }
                let row = rows[state.index]
                var dirty = state.dirty
                var cause = entry.cause
                func rejectReader(_ kind: String) -> Bool {
                    if state.loopStale {
                        reject(.loopStaleVersion, row, "flag-live loop writes compare operand physical register; reader=\(kind)")
                        return true
                    }
                    if dirty {
                        // A dirty path is rejected only here, never at the write itself.
                        // A later fresh definition/ABI boundary can still end it safely.
                        if let cause {
                            rejection = .init(reason: cause.reason, address: row.source.address,
                                detail: "reader=\(kind); \(row.operation); first dirty at 0x\(String(cause.address, radix: 16)): \(cause.detail)")
                        }
                        return true
                    }
                    if !restates(row.operation, source: row.source) {
                        reject(.notRestated(kind), row, "reader=\(kind); compare operands=\(operands)")
                        return true
                    }
                    return false
                }
                var targets: [MacIRValue] = []
                var fallthroughEdge = true
                switch row.operation {
                case .intrinsic(_, "compare", _): continue // fresh NZCV definition
                case .returnValue, .call: continue // flags do not survive the ABI boundary
                case let .conditionalBranch(_, _, _, target):
                    // CBZ/TBZ consume their value directly, not the reaching NZCV.
                    if !["cbz", "cbnz", "tbz", "tbnz"].contains(row.source.mnemonic) {
                        if rejectReader("conditionalBranch") { continue }
                        sawReader = true
                    }
                    targets = [target]
                case .select:
                    if rejectReader("select") { continue }
                    sawReader = true
                case .compareToBool:
                    if rejectReader("compareToBool") { continue }
                    sawReader = true
                case let .unknown(_, inputs, _, _):
                    if inputs.mayReadNZCV { reject(.unknownReader, row); continue }
                    // Unmodeled operations may overwrite storage beyond the claimed
                    // scalar destination. A later explicit reader needs a fresh proof.
                    if !dirty {
                        cause = .init(reason: .dirtyUnknownOp, address: row.source.address,
                            detail: "\(row.source.mnemonic) \(row.source.operands); \(row.operation)")
                    }
                    dirty = true
                case let .intrinsic(destination, name, arguments):
                    if ["restore_pair_writeback", "save_pair_writeback"].contains(name),
                       !validPairWriteback(destination, name, arguments) {
                        reject(.nonFlagIndependentIntrinsic(name), row, "malformed pair-writeback contract: \(name)")
                        continue
                    }
                    if name == "branch", arguments.count == 1 {
                        targets = arguments
                        fallthroughEdge = false
                    } else if !flagIndependentIntrinsics.contains(name) && !typedIndependentIntrinsic(row) {
                        reject(row.source.mnemonic == "ccmp" || row.source.mnemonic == "ccmn"
                            ? .ccmp : .nonFlagIndependentIntrinsic(name), row, "intrinsic=\(name)")
                        continue
                    }
                case let .switchDispatch(_, cases, defaultTarget):
                    guard let defaultTarget else { reject(.switchWithoutDefault, row); continue }
                    targets = cases.map(\.target) + [defaultTarget]
                    fallthroughEdge = false
                default: break
                }
                // A flag-setting instruction's own readers are evaluated first.
                if MacIRBuilder.writesNZCVFlags(row.source.mnemonic) { continue }
                if !dirty, let reason = clobberReason(row.operation) {
                    dirty = true
                    cause = .init(reason: reason, address: row.source.address,
                        detail: "\(row.source.mnemonic) \(row.source.operands); \(row.operation)")
                }
                func pendingAt(_ index: Int, phis: [MacIRPhi]) -> Pending {
                    if !dirty, let phi = phis.first(where: { clobberedDefinition($0.destination) != nil }) {
                        return Pending(state: State(index: index, dirty: true, loopStale: state.loopStale), cause:
                            .init(reason: .phiClobber, address: phi.blockAddress, detail: "phi destination=\(phi.destination)"))
                    }
                    return Pending(state: State(index: index, dirty: dirty, loopStale: state.loopStale), cause: cause)
                }
                for target in targets {
                    guard case let .immediate(address) = target else {
                        reject(.unresolvedInteriorEdge, row, "non-immediate edge=\(target)")
                        break
                    }
                    let destination = UInt64(bitPattern: address)
                    if let index = addressIndices[destination] {
                        pending.append(pendingAt(index, phis: phisByAddress[destination] ?? []))
                    } else if (firstAddress...lastAddress).contains(destination) {
                        reject(.unresolvedInteriorEdge, row, "missing interior address=0x\(String(destination, radix: 16))")
                    } // A direct transfer out of this function is an exit.
                }
                if fallthroughEdge {
                    let next = state.index + 1
                    let phis = rows.indices.contains(next) ? (phisByAddress[rows[next].source.address] ?? []) : []
                    pending.append(pendingAt(next, phis: phis))
                }
            }
            if function.ssaFlagPhiComparisons.contains(compare.source.address) {
                // A27: the flags-phi edge boolean fully captures this comparison.
                result[compareIndex] = .elide
            } else if let rejection {
                result[compareIndex] = .keep(rejection)
            } else if sawReader {
                result[compareIndex] = .elide
            } else {
                result[compareIndex] = .keep(.init(reason: .noReader, address: compare.source.address,
                    detail: "No explicit flag reader before a fresh flag definition, ABI boundary, exit, or visited state"))
            }
        }
        return result
    }
}

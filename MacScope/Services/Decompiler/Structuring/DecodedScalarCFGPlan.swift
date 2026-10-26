import Foundation

/// A whole-function, decoded physical-state certificate. The canonical re-lift
/// below establishes correspondence to the pinned producer, not path validity:
/// initialized-width dataflow and decoded control/effect proofs are independent.
/// No input IR, source row, CFG, parameter, or naming context is changed.
struct DecodedScalarCFGPlan {
    struct Declaration {
        let storage: MacIRValue
        let initializer: MacIRValue?
    }

    enum Effect {
        case assign(destination: MacIRValue, value: MacIRValue)
        /// An unsigned fixed-width read, zero-extended into uint64_t storage.
        case load(destination: MacIRValue, address: MacIRValue, byteWidth: Int)
        case store(value: MacIRValue, address: MacIRValue, byteWidth: Int)
    }

    struct Entry {
        let register: GPR
        let value: MacIRValue
        let type: String
        let initializedMask: UInt8
    }
    struct ConditionOrigin {
        let consumerRow: Int
        let writerRow: Int?
        let condition: String
    }

    /// Read-only facts from this certificate's exact decoder/re-lift proof.
    /// Consumers do not parse another grammar or print the physical cells.
    let certifiedRows: [Row]
    let entries: [Entry]
    let conditionOrigins: [Int: ConditionOrigin]
    let originalAtoms: Set<MacIRValue>
    let declarations: [Declaration]
    /// Exactly one ordered group per original source row, including controls.
    let groups: [[Effect]]
    let branchConditions: [Int: BranchCondition]
    /// A test boundary, never permission to suppress a writer's effect group.
    let testPrefixStarts: [Int: Int]
    let namedValues: Set<MacIRValue>
    let provedPositions: Set<RegionalProvedPosition>
    private let originalFunction: MacIRFunction
    private let originalInstructions: [MacIRInstruction]
    private let originalCFG: CFG

    func matches(cfg: CFG, instructions: [MacIRInstruction]) -> Bool {
        instructions == originalInstructions && Self.sameCFG(cfg, originalCFG)
    }

    func matches(function: MacIRFunction, cfg: CFG) -> Bool {
        function == originalFunction && Self.sameCFG(cfg, originalCFG)
    }

    static func prove(function: MacIRFunction, cfg: CFG,
                      lexicalProof: RegionalLexicalProof? = nil,
                      attemptLexical: Bool = true) -> Self? {
        if attemptLexical, lexicalProof == nil,
           let proof = RegionalLexicalProof(reconciled: function),
           let result = prove(function: proof.function, cfg: cfg, lexicalProof: proof,
                              attemptLexical: false) {
            return result
        }
        // A declined lexical candidate does not disable the prior row proof.

        let rows = function.instructions
        guard !rows.isEmpty, rows.first?.source.address == function.startAddress,
              (function.phis.isEmpty || function.ssaEnabled), !function.isVariadic, !function.isNoReturn,
              !function.observesFPSR, function.stackFrameSize == 0,
              function.localVariables.isEmpty, function.callTargets.isEmpty,
              function.callSignatures.isEmpty,
              Set(function.parameters.map(\.name)).count == function.parameters.count,
              Set(function.parameters.map(\.id)).count == function.parameters.count,
              Set(function.parameters.compactMap(\.bindingID)).count == function.parameters.count,
              !cfg.blocks.isEmpty, cfg.entryIndex == 0,
              cfg.blocks[0].predecessors.isEmpty,
              !cfg.hasUnresolvedTargets, cfg.irreducibleBlocks.isEmpty,
              sameCFG(cfg, CFGBuilder.buildCFG(instructions: rows)) else { return nil }

        var decoded: [Row] = []
        for (index, instruction) in rows.enumerated() {
            guard instruction == MacIRInstruction(source: instruction.source,
                    operation: instruction.operation, memoryAccess: instruction.memoryAccess,
                    returnTarget: instruction.returnTarget),
                  instruction.returnTarget == nil,
                  index == 0 || rows[index - 1].source.address.isContiguous(to: instruction.source.address),
                  canonicalEvidence(instruction.source),
                  let row = parse(instruction.source) else { return nil }
            if case .returned = row {
                guard instruction.memoryAccess == nil,
                      case let .returnValue(value) = instruction.operation,
                      value == nil || value == .unknown("unresolved_return_contract") else { return nil }
            }
            decoded.append(row)
        }
        guard Set(rows.map { $0.source.address }).count == rows.count,
              decoded.contains(where: { if case .returned = $0 { return true }; return false }),
              proveEdges(decoded, instructions: rows, cfg: cfg) else { return nil }

        // Build-time records establish correspondence with the actual inputs.
        // Without records, retain the existing exact producer replay.
        guard lexicalProof == nil || lexicalProof?.function == function else { return nil }
        let relifted: MacIRFunction
        if function.ssaEnabled {
            // Persisted phis are not removed or rewritten. Their exact producer
            // identity precedes the independent decoded machine-state proof.
            guard function.ssaOriginalInstructions == rows,
                  function.ssaOriginalPhis == function.phis else { return nil }
            relifted = MacIRBuilder(explicitCFGEnabled: function.cfg != nil, ssaEnabled: true)
                .buildFunction(name: function.name, startAddress: function.startAddress,
                    instructions: rows.map { SourceRow(source: $0.source) })
        } else {
            relifted = lexicalProof?.function ?? MacIRBuilder(explicitCFGEnabled: function.cfg != nil, ssaEnabled: false)
                .buildFunction(name: function.name,
                startAddress: function.startAddress, instructions: rows.map { SourceRow(source: $0.source) })
        }
        guard relifted == function else { return nil }

        var entryMasks = Array(repeating: UInt8(0), count: 30)
        var initializers: [Int: MacIRValue] = [:]
        var named: Set<MacIRValue> = []
        var entries: [Entry] = []
        for parameter in function.parameters {
            guard parameter.richLocation == nil,
                  case let .gpr(index, width) = parameter.abiLocation,
                  (0..<8).contains(index), [32, 64].contains(width),
                  parameter.bindingID == .gpr(index),
                  let view = GPR(parameter.register), !view.isZero,
                  view.index == index, view.width == width,
                  (width == 32 ? ["int32_t", "uint32_t"] : ["int64_t", "uint64_t"]).contains(parameter.type),
                  initializers[index] == nil else { return nil }
            let argument = MacIRValue.argument(bindingID: .gpr(index))
            initializers[index] = commit(argument, width: width)
            // A W ABI formal gives only low32 incoming architectural bits.
            // Its convenient zero-extended initializer does not prove high32.
            entryMasks[index] = width == 32 ? 1 : 3
            entries.append(Entry(register: view, value: argument, type: parameter.type,
                initializedMask: entryMasks[index]))
            named.insert(argument)
        }
        guard initializedReads(decoded, cfg: cfg, entryMasks: entryMasks) else { return nil }
        var provedPositions = Set(decoded.enumerated().flatMap { index, row in
            row.reads.filter { !$0.isZero }.map {
                RegionalProvedPosition(address: rows[index].source.address, register: $0.index, width: $0.width)
            }
        })
        provedPositions.formUnion(RegionalLexicalProof.flagPositions(
            function: function, cfg: cfg, provedReads: provedPositions))
        guard lexicalProof?.isCovered(by: provedPositions) != false else { return nil }

        let registers = Set(decoded.flatMap { $0.reads + $0.writes }
            .filter { !$0.isZero }.map(\.index)).sorted()
        var declarations = registers.map { register in
            Declaration(storage: cell(register), initializer: initializers[register])
        }
        var groups = decoded.enumerated().map { effects($0.element, at: $0.offset) }
        for (index, row) in decoded.enumerated() {
            if case .pair = row {
                for ordinal in 0..<3 {
                    declarations.append(Declaration(storage: pair(index, ordinal), initializer: nil))
                }
            }
        }

        var branches: [Int: BranchCondition] = [:]
        var prefixes: [Int: Int] = [:]
        var origins: [Int: ConditionOrigin] = [:]
        var provedNonentrySUBSSelfLoop = false
        for block in cfg.blocks {
            var writer: Int?
            for index in block.instructionRange {
                switch decoded[index] {
                case .compare, .binary(_, _, _, _, true):
                    writer = index
                case let .conditional(condition, target):
                    guard let writer,
                          let predicate = predicate(condition, writer: decoded[writer]) else { return nil }
                    let snapshot = MacIRValue.register(name: "rgn_cfg_flag\(index)", version: 0)
                    declarations.append(Declaration(storage: snapshot, initializer: nil))
                    groups[writer].append(.assign(destination: snapshot, value: project(predicate, 64)))
                    branches[index] = BranchCondition(branchIndex: index, compareIndex: nil,
                        left: snapshot, condition: "!=", right: .immediate(0), isZeroCheck: false)
                    prefixes[index] = writer
                    origins[index] = ConditionOrigin(consumerRow: index, writerRow: writer, condition: condition)
                    if block.index != cfg.entryIndex,
                       target == rows[block.startIndex].source.address,
                       cfg.backEdges.contains(CFGEdge(block.index, block.index)),
                       case .binary(_, "-", _, _, true) = decoded[writer] {
                        provedNonentrySUBSSelfLoop = true
                    }
                case let .zero(register, _):
                    branches[index] = BranchCondition(branchIndex: index, compareIndex: nil,
                        left: read(register), condition: "==", right: .immediate(0), isZeroCheck: true)
                    prefixes[index] = index
                    origins[index] = ConditionOrigin(consumerRow: index, writerRow: nil, condition: "eq")
                default:
                    break // Every other admitted row is known to preserve NZCV.
                }
            }
        }
        guard provedNonentrySUBSSelfLoop else { return nil }
        for instruction in rows {
            guard let operands = originalValues(instruction.operation) else { return nil }
            for value in operands { collectAtoms(value, into: &named) }
        }
        let originalAtoms = named
        for declaration in declarations {
            named.insert(declaration.storage)
            if let initializer = declaration.initializer { collectAtoms(initializer, into: &named) }
        }
        guard Set(declarations.map(\.storage)).count == declarations.count else { return nil }
        return Self(certifiedRows: decoded, entries: entries, conditionOrigins: origins,
            originalAtoms: originalAtoms, declarations: declarations, groups: groups, branchConditions: branches,
            testPrefixStarts: prefixes, namedValues: named, provedPositions: provedPositions, originalFunction: function,
            originalInstructions: rows, originalCFG: cfg)
    }

    private struct SourceRow: DecompilerInstructionRow {
        let source: MacIRSourceSpan
        var address: UInt64 { source.address }
        var bytes: String { source.byteText }
        var mnemonic: String { source.mnemonic }
        var operands: String { source.operands }
        var comment: String? { source.comment }
        var structuredOperands: InstructionOperands? { source.structuredOperands }
    }

    struct GPR: Hashable {
        let index: Int
        let width: Int
        var isZero: Bool { index == 31 }

        init?(_ text: String) {
            guard let first = text.first, first == "w" || first == "x" else { return nil }
            width = first == "w" ? 32 : 64
            if text == "wzr" || text == "xzr" { index = 31; return }
            guard let value = Int(text.dropFirst()), (0..<30).contains(value),
                  text == "\(first)\(value)" else { return nil }
            index = value
        }
    }

    enum Operand {
        case register(GPR)
        case immediate(Int64)
        var reads: [GPR] {
            if case let .register(register) = self { return [register] }
            return []
        }
    }

    struct Address {
        let base: GPR
        let index: GPR?
        let shift: Int
        let displacement: Int64
        var reads: [GPR] { [base] + (index.map { [$0] } ?? []) }
        var value: MacIRValue {
            var result = DecodedScalarCFGPlan.read(base)
            if let index {
                var offset = DecodedScalarCFGPlan.project(DecodedScalarCFGPlan.read(index), 64)
                if shift != 0 { offset = .binaryExpression(op: "<<", left: offset, right: .immediate(Int64(shift))) }
                result = .binaryExpression(op: "+", left: result, right: offset)
            }
            if displacement != 0 {
                result = .binaryExpression(op: "+", left: result,
                    right: DecodedScalarCFGPlan.project(.immediate(displacement), 64))
            }
            return DecodedScalarCFGPlan.project(result, 64)
        }
    }

    enum Row {
        case load(GPR, Address, Int, Int64?)
        case store(GPR, Address, Int, Int64?)
        case pair(GPR, GPR, Address)
        case move(GPR, Operand)
        case binary(GPR, String, Operand, Operand, Bool)
        case signExtend(GPR, GPR)
        case compare(GPR, Operand)
        case conditional(String, UInt64)
        case zero(GPR, UInt64)
        case jump(UInt64)
        case returned

        var reads: [GPR] {
            switch self {
            case let .load(_, address, _, _), let .pair(_, _, address): return address.reads
            case let .store(value, address, _, _): return [value] + address.reads
            case let .move(_, source): return source.reads
            case let .binary(_, _, left, right, _): return left.reads + right.reads
            case let .signExtend(_, source): return [source]
            case let .compare(left, right): return [left] + right.reads
            case let .zero(value, _): return [value]
            case .conditional, .jump, .returned: return []
            }
        }
        var writes: [GPR] {
            switch self {
            case let .load(destination, address, _, delta):
                return [destination] + (delta == nil ? [] : [address.base])
            case let .move(destination, _),
                 let .binary(destination, _, _, _, _), let .signExtend(destination, _):
                return [destination]
            case let .store(_, address, _, delta): return delta == nil ? [] : [address.base]
            case let .pair(first, second, _): return [first, second]
            case .compare, .conditional, .zero, .jump, .returned: return []
            }
        }
        var isControl: Bool {
            switch self {
            case .conditional, .zero, .jump, .returned: return true
            default: return false
            }
        }
    }

    private static func parse(_ source: MacIRSourceSpan) -> Row? {
        let operands = MacIRBuilder.splitOperands(source.operands)
        switch source.mnemonic {
        case "ldr", "ldrb", "ldrh", "ldurb", "ldurh":
            guard (2...3).contains(operands.count),
                  let destination = GPR(operands[0]), !destination.isZero,
                  source.mnemonic == "ldr" || destination.width == 32,
                  let address = address(operands[1]) else { return nil }
            let width = source.mnemonic == "ldr" ? destination.width / 8 :
                (source.mnemonic.hasSuffix("b") ? 1 : 2)
            if operands.count == 3 {
                guard source.mnemonic == "ldrb" || source.mnemonic == "ldrh",
                      address.index == nil, address.displacement == 0,
                      destination.index != address.base.index,
                      let delta = MacIRBuilder.parseImmediate(operands[2]) else { return nil }
                return .load(destination, address, width, delta)
            }
            // Preserve old LDR/LDRB addressing, but do not introduce indexed
            // halfword or unscaled forms beyond the observed offset grammar.
            guard source.mnemonic == "ldr" || source.mnemonic == "ldrb" || address.index == nil else { return nil }
            return .load(destination, address, width, nil)
        case "strb", "strh", "sturb", "sturh":
            guard (2...3).contains(operands.count), let value = GPR(operands[0]), value.width == 32,
                  let address = address(operands[1]) else { return nil }
            let width = source.mnemonic.hasSuffix("b") ? 1 : 2
            if operands.count == 3 {
                guard source.mnemonic == "strb" || source.mnemonic == "strh",
                      address.index == nil, address.displacement == 0,
                      value.isZero || value.index != address.base.index,
                      let delta = MacIRBuilder.parseImmediate(operands[2]) else { return nil }
                return .store(value, address, width, delta)
            }
            if source.mnemonic.hasPrefix("stur") {
                guard address.index == nil else { return nil }
            } else {
                // Plain X-register indexing is needed by the actual generic
                // conversion arm. No new extension or shift is admitted.
                guard source.mnemonic == "strb" || address.index == nil,
                      MacIRBuilder.splitOperands(String(operands[1].dropFirst().dropLast())).count <= 2 else { return nil }
            }
            return .store(value, address, width, nil)
        case "ldp":
            guard operands.count == 3, let first = GPR(operands[0]), let second = GPR(operands[1]),
                  first.width == 64, second.width == 64, !first.isZero, !second.isZero,
                  first.index != second.index, let address = address(operands[2]), address.index == nil,
                  first.index != address.base.index, second.index != address.base.index else { return nil }
            return .pair(first, second, address)
        case "mov":
            guard operands.count == 2, let destination = GPR(operands[0]), !destination.isZero,
                  let source = operand(operands[1], width: destination.width) else { return nil }
            return .move(destination, source)
        case "add", "sub", "subs":
            guard operands.count == 3, let destination = GPR(operands[0]), !destination.isZero,
                  source.mnemonic != "sub" || destination.width == 32,
                  source.mnemonic != "subs" || destination.width == 64,
                  let leftRegister = GPR(operands[1]), leftRegister.width == destination.width,
                  let right = operand(operands[2], width: destination.width) else { return nil }
            return .binary(destination, source.mnemonic == "add" ? "+" : "-",
                .register(leftRegister), right, source.mnemonic == "subs")
        case "sxtw":
            guard operands.count == 2, let destination = GPR(operands[0]),
                  destination.width == 64, !destination.isZero,
                  let source = GPR(operands[1]), source.width == 32 else { return nil }
            return .signExtend(destination, source)
        case "cmp":
            guard operands.count == 2, let left = GPR(operands[0]),
                  let right = operand(operands[1], width: left.width) else { return nil }
            return .compare(left, right)
        case "b.eq", "b.ne", "b.lt", "b.gt", "b.lo", "b.hs":
            guard operands.count == 1, let target = target(operands[0]) else { return nil }
            return .conditional(String(source.mnemonic.dropFirst(2)), target)
        case "cbz":
            guard operands.count == 2, let register = GPR(operands[0]), register.width == 32,
                  let target = target(operands[1]) else { return nil }
            return .zero(register, target)
        case "b":
            guard operands.count == 1, let target = target(operands[0]) else { return nil }
            return .jump(target)
        case "ret":
            return source.operands.isEmpty ? .returned : nil
        default:
            return nil
        }
    }

    private static func operand(_ text: String, width: Int) -> Operand? {
        if let register = GPR(text), register.width == width { return .register(register) }
        if let value = MacIRBuilder.parseImmediate(text) { return .immediate(value) }
        return nil
    }

    private static func address(_ text: String) -> Address? {
        guard text.hasPrefix("["), text.hasSuffix("]") else { return nil }
        let parts = MacIRBuilder.splitOperands(String(text.dropFirst().dropLast()))
        guard (1...3).contains(parts.count), let base = parts.first.flatMap(GPR.init),
              base.width == 64, !base.isZero else { return nil }
        if parts.count == 1 { return Address(base: base, index: nil, shift: 0, displacement: 0) }
        if parts.count == 2, let offset = MacIRBuilder.parseImmediate(parts[1]) {
            return Address(base: base, index: nil, shift: 0, displacement: offset)
        }
        guard let index = GPR(parts[1]) else { return nil }
        if parts.count == 2 {
            guard index.width == 64 else { return nil }
            return Address(base: base, index: index, shift: 0, displacement: 0)
        }
        let modifier = parts[2].split(separator: " ").map(String.init)
        guard (1...2).contains(modifier.count),
              (modifier[0] == "uxtw" && index.width == 32) ||
                (modifier[0] == "lsl" && index.width == 64) else { return nil }
        let shift: Int64
        if modifier.count == 1 { shift = 0 }
        else {
            guard let parsed = MacIRBuilder.parseImmediate(modifier[1]) else { return nil }
            shift = parsed
        }
        guard (0..<64).contains(shift) else { return nil }
        return Address(base: base, index: index, shift: Int(shift), displacement: 0)
    }

    private static func target(_ text: String) -> UInt64? {
        if text.hasPrefix("0x") { return UInt64(text.dropFirst(2), radix: 16) }
        return UInt64(text)
    }

    private static func canonicalEvidence(_ source: MacIRSourceSpan) -> Bool {
        guard let envelope = source.structuredOperands else { return false }
        let tokens = source.byteText.split(separator: " ")
        guard tokens.count == 4 else { return false }
        var bytes: [UInt8] = []
        for token in tokens {
            guard token.utf8.count == 2,
                  token.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }),
                  let byte = UInt8(token, radix: 16) else { return false }
            bytes.append(byte)
        }
        let decoded = ARM64Decoder().decode(Data(bytes), baseAddress: source.address, maxInstructionCount: 1)
        guard decoded.count == 1, let row = decoded.first, row.address == source.address,
              row.bytes == bytes, row.mnemonic == source.mnemonic, row.operands == source.operands,
              row.structuredOperands == envelope else { return false }
        switch envelope.coverage {
        case .complete: return envelope.rendersExactly(mnemonic: source.mnemonic, operands: source.operands)
        case .unavailable: return envelope == .unavailable(mnemonic: source.mnemonic, operands: source.operands)
        case .partial: return false
        }
    }

    private static func proveEdges(_ rows: [Row], instructions: [MacIRInstruction], cfg: CFG) -> Bool {
        let byAddress = Dictionary(uniqueKeysWithValues: instructions.enumerated().map { ($0.element.source.address, $0.offset) })
        func block(at target: UInt64) -> Int? {
            byAddress[target].flatMap { cfg.blockByStartIndex[$0] }
        }
        var visited: Set<Int> = []
        var pending = [cfg.entryIndex]
        while let index = pending.popLast() {
            guard cfg.blocks.indices.contains(index) else { return false }
            if visited.insert(index).inserted { pending.append(contentsOf: cfg.blocks[index].successors) }
        }
        guard visited.count == cfg.blocks.count else { return false }
        for basic in cfg.blocks {
            guard !basic.instructionRange.isEmpty, basic.startIndex >= 0, basic.endIndex <= rows.count,
                  !basic.instructionRange.dropLast().contains(where: { rows[$0].isControl }) else { return false }
            let last = basic.endIndex - 1
            let expected: [Int]
            switch rows[last] {
            case let .conditional(_, target), let .zero(_, target):
                guard let taken = block(at: target), let fallthroughBlock = cfg.blockByStartIndex[basic.endIndex],
                      taken != fallthroughBlock,
                      case let .conditionalBranch(_, _, _, typedTarget) = instructions[last].operation,
                      typedTarget == .immediate(Int64(bitPattern: target)) else { return false }
                expected = [taken, fallthroughBlock]
            case let .jump(target):
                guard let taken = block(at: target),
                      case let .intrinsic(destination, "branch", arguments) = instructions[last].operation,
                      destination == nil, arguments == [.immediate(Int64(bitPattern: target))] else { return false }
                expected = [taken]
            case .returned:
                guard case .returnValue = instructions[last].operation else { return false }
                expected = []
            default:
                guard let next = cfg.blockByStartIndex[basic.endIndex] else { return false }
                expected = [next]
            }
            guard basic.successors == expected else { return false }
        }
        return true
    }

    private static func initializedReads(_ rows: [Row], cfg: CFG, entryMasks: [UInt8]) -> Bool {
        // Greatest fixed point for a must-analysis. Writes establish all64;
        // the fixed ABI-entry boundary removes unsupported first-entry facts.
        let top = Array(repeating: UInt8(3), count: 30)
        var incoming = Array(repeating: top, count: cfg.blocks.count)
        var outgoing = incoming
        var changed = true
        while changed {
            changed = false
            for block in cfg.blocks {
                var input = block.index == cfg.entryIndex ? entryMasks : top
                if block.index != cfg.entryIndex {
                    guard !block.predecessors.isEmpty else { return false }
                    for predecessor in block.predecessors {
                        for register in input.indices { input[register] &= outgoing[predecessor][register] }
                    }
                }
                var output = input
                for index in block.instructionRange {
                    for destination in rows[index].writes { output[destination.index] = 3 }
                }
                if incoming[block.index] != input || outgoing[block.index] != output {
                    incoming[block.index] = input; outgoing[block.index] = output; changed = true
                }
            }
        }
        for block in cfg.blocks {
            var available = incoming[block.index]
            for index in block.instructionRange {
                for register in rows[index].reads where !register.isZero {
                    let required: UInt8 = register.width == 32 ? 1 : 3
                    guard available[register.index] & required == required else { return false }
                }
                for register in rows[index].writes { available[register.index] = 3 }
            }
        }
        return true
    }

    private static func effects(_ row: Row, at index: Int) -> [Effect] {
        switch row {
        case let .load(destination, address, width, delta):
            var result: [Effect] = [.load(destination: cell(destination.index), address: address.value, byteWidth: width)]
            if let delta { result.append(writeback(address, delta: delta)) }
            return result
        case let .store(value, address, width, delta):
            var result: [Effect] = [.store(value: project(read(value), width * 8), address: address.value, byteWidth: width)]
            if let delta { result.append(writeback(address, delta: delta)) }
            return result
        case let .pair(first, second, address):
            return [.assign(destination: pair(index, 0), value: address.value),
                .load(destination: pair(index, 1), address: pair(index, 0), byteWidth: 8),
                .load(destination: pair(index, 2), address: project(.binaryExpression(op: "+",
                    left: pair(index, 0), right: project(.immediate(8), 64)), 64), byteWidth: 8),
                .assign(destination: cell(first.index), value: pair(index, 1)),
                .assign(destination: cell(second.index), value: pair(index, 2))]
        case let .move(destination, source):
            return [.assign(destination: cell(destination.index), value: commit(value(source), width: destination.width))]
        case let .binary(destination, operation, left, right, _):
            let expression = MacIRValue.binaryExpression(op: operation,
                left: project(value(left), destination.width), right: project(value(right), destination.width))
            return [.assign(destination: cell(destination.index), value: commit(expression, width: destination.width))]
        case let .signExtend(destination, source):
            return [.assign(destination: cell(destination.index), value: project(
                .unary(op: "(int64_t)", value: .unary(op: "(int32_t)", value: read(source))), 64))]
        case .compare, .conditional, .zero, .jump, .returned:
            return []
        }
    }

    private static func writeback(_ address: Address, delta: Int64) -> Effect {
        // The memory effect precedes this update, and post-index source/base
        // aliases have already been rejected. Both additions wrap at 64 bits.
        .assign(destination: cell(address.base.index), value: project(.binaryExpression(op: "+",
            left: read(address.base), right: project(.immediate(delta), 64)), 64))
    }

    private static func predicate(_ condition: String, writer: Row) -> MacIRValue? {
        let operation: String
        switch condition {
        case "eq": operation = "=="
        case "ne": operation = "!="
        case "lt", "lo": operation = "<"
        case "gt": operation = ">"
        case "hs": operation = ">="
        default: return nil
        }
        switch writer {
        case let .compare(left, right):
            var lhs = read(left), rhs = project(value(right), left.width)
            if condition == "lt" || condition == "gt" {
                lhs = .unary(op: "(int\(left.width)_t)", value: lhs)
                rhs = .unary(op: "(int\(left.width)_t)", value: rhs)
            }
            return .binaryExpression(op: operation, left: lhs, right: rhs)
        case let .binary(destination, "-", _, _, true):
            guard condition == "eq" || condition == "ne" else { return nil }
            // The arithmetic commit precedes this snapshot in the same group.
            return .binaryExpression(op: operation, left: read(destination), right: project(.immediate(0), 64))
        default: return nil
        }
    }

    private static func cell(_ register: Int) -> MacIRValue {
        .register(name: "rgn_cfg_r\(register)", version: 0)
    }
    private static func pair(_ row: Int, _ ordinal: Int) -> MacIRValue {
        .register(name: "rgn_cfg_pair\(row)_\(ordinal)", version: 0)
    }
    private static func project(_ value: MacIRValue, _ width: Int) -> MacIRValue {
        .unary(op: "(uint\(width)_t)", value: value)
    }
    private static func commit(_ value: MacIRValue, width: Int) -> MacIRValue {
        project(project(value, width), 64)
    }
    private static func read(_ register: GPR) -> MacIRValue {
        project(register.isZero ? .immediate(0) : cell(register.index), register.width)
    }
    private static func value(_ operand: Operand) -> MacIRValue {
        switch operand {
        case let .register(register): return read(register)
        case let .immediate(immediate): return .immediate(immediate)
        }
    }

    private static func sameCFG(_ left: CFG, _ right: CFG) -> Bool {
        left.blocks == right.blocks && left.entryIndex == right.entryIndex &&
        left.domTree == right.domTree && left.postDomTree == right.postDomTree &&
        left.loopHeaders == right.loopHeaders && left.backEdges == right.backEdges &&
        left.irreducibleBlocks == right.irreducibleBlocks &&
        left.blockByStartIndex == right.blockByStartIndex && left.hasUnresolvedTargets == right.hasUnresolvedTargets
    }

    private static func originalValues(_ operation: MacIROperation) -> [MacIRValue]? {
        switch operation {
        case let .assign(destination, source): return [destination, source]
        case let .binary(destination, _, left, right): return [destination, left, right]
        case let .load(destination, address): return [destination, address]
        case let .loadWriteback(destination, baseDestination, baseSource, _, _):
            return [destination, baseDestination, baseSource]
        case let .store(source, address): return [source, address]
        case let .storeWriteback(source, destination, base, _, _): return [source, destination, base]
        case let .conditionalBranch(_, left, right, target): return [left, right, target]
        case let .returnValue(value): return value.map { [$0] } ?? []
        case let .intrinsic(destination, _, arguments): return (destination.map { [$0] } ?? []) + arguments
        default: return nil
        }
    }

    private static func collectAtoms(_ value: MacIRValue, into result: inout Set<MacIRValue>) {
        switch value {
        case .register, .argument, .temporary: result.insert(value)
        case let .signedBitfield(node): collectAtoms(node.source, into: &result)
        case let .unary(_, inner), let .bitTest(inner, _): collectAtoms(inner, into: &result)
        case let .binaryExpression(_, left, right):
            collectAtoms(left, into: &result); collectAtoms(right, into: &result)
        default: break
        }
    }
}

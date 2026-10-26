import Foundation

/// DP04 A3: BinExport operand expression trees from a row's complete typed sidecar.
/// Used only when the sidecar renders back to exactly the row's text. Trees match
/// the text parser wherever its reading is right (registers, immediates, plain and
/// post-index memory, shifted operands, branch targets) and improve two forms it
/// reads as symbols: vector registers (`v0.4s`, `v2.s[1]`) and an extended or
/// shifted memory index (`[x4, w5, uxtw #2]`). Anything unsupported returns nil, and
/// the exporter keeps the text parser for that row.
extension BinExport2OperandParser {
    public static func structuredOperandTrees(_ sidecar: InstructionOperands?, mnemonic: String,
                                              operands: String) -> [[ExprNode]]? {
        guard let sidecar, sidecar.architecture == .arm64,
              sidecar.rendersExactly(mnemonic: mnemonic, operands: operands) else { return nil }
        var omitted = Set(sidecar.presentation.omittedOperandIndices)
        if let suffix = sidecar.presentation.conditionSuffixOperandIndex { omitted.insert(suffix) }
        var trees: [[ExprNode]] = []
        for (index, operand) in sidecar.operands.enumerated() where !omitted.contains(index) {
            guard let converted = operandTrees(for: operand, presentation: sidecar.presentation) else { return nil }
            trees.append(contentsOf: converted)
        }
        return trees
    }

    private static func operandTrees(for operand: InstructionOperands.Operand,
                              presentation: InstructionOperands.Presentation) -> [[ExprNode]]? {
        switch operand {
        case let .register(register):
            return registerSpelling(register).map { [[ExprNode(kind: .register, symbol: $0)]] }
        case let .immediate(immediate):
            return integer(immediate).map { [[ExprNode(kind: .immediateInt, immediate: $0)]] }
        case let .modifiedRegister(register, modifier):
            guard let spelling = registerSpelling(register) else { return nil }
            return [modified(ExprNode(kind: .register, symbol: spelling), modifier)]
        case let .modifiedImmediate(immediate, modifier):
            guard let value = integer(immediate) else { return nil }
            return [modified(ExprNode(kind: .immediateInt, immediate: value), modifier)]
        case let .memory(memory):
            return memoryTrees(memory, presentation: presentation)
        case let .pcRelative(reference):
            return reference.target.map { [[ExprNode(kind: .immediateInt, immediate: $0)]] }
        case let .condition(condition):
            return [[ExprNode(kind: .symbol, symbol: condition.rawValue)]]
        case let .systemRegister(register):
            return register.spelling.map { [[ExprNode(kind: .symbol, symbol: $0)]] }
        case let .option(option):
            return option.spelling.map { [[ExprNode(kind: .symbol, symbol: $0)]] }
        case .registerList, .opaque:
            return nil
        }
    }

    static func registerSpelling(_ register: InstructionOperands.Register) -> String? {
        switch register.bank {
        case .general:
            switch register.role {
            case .stackPointer: return register.width == 64 ? "sp" : "wsp"
            case .zero: return register.width == 64 ? "xzr" : "wzr"
            case .ordinary:
                guard (0...30).contains(register.index), [32, 64].contains(register.width) else { return nil }
                return "\(register.width == 64 ? "x" : "w")\(register.index)"
            }
        case .simd:
            guard (0...31).contains(register.index) else { return nil }
            let suffixes = [8: "b", 16: "h", 32: "s", 64: "d", 128: "q"]
            if let arrangement = register.arrangement {
                guard let suffix = suffixes[arrangement.elementWidth] else { return nil }
                if let lanes = arrangement.laneCount { return "v\(register.index).\(lanes)\(suffix)" }
                guard let lane = register.lane else { return nil }
                return "v\(register.index).\(suffix)[\(lane)]"
            }
            return suffixes[register.width].map { "\($0)\(register.index)" }
        }
    }

    private static func integer(_ immediate: InstructionOperands.Immediate) -> UInt64? {
        switch immediate.value {
        case let .signed(value): return UInt64(bitPattern: value)
        case let .unsigned(value): return value
        case .floatingPoint: return nil
        }
    }

    /// `op(modifier) → base [, #amount]`, the shape `parseShiftOrExtend` builds.
    private static func modified(_ base: ExprNode, _ modifier: InstructionOperands.RegisterModifier) -> [ExprNode] {
        let amount = modifier.amount ?? 0
        if modifier.omitWhenZero && amount == 0 { return [base] }
        var root = base; root.parentIndex = 0
        var nodes = [ExprNode(kind: .op, symbol: (modifier.presentationKind ?? modifier.kind).rawValue), root]
        if modifier.amount != nil, !(modifier.omitZeroAmount && amount == 0) {
            nodes.append(ExprNode(kind: .immediateInt, immediate: UInt64(amount), parentIndex: 0))
        }
        return nodes
    }

    private static func memoryTrees(_ memory: InstructionOperands.Memory,
                                    presentation: InstructionOperands.Presentation) -> [[ExprNode]]? {
        guard let base = registerSpelling(memory.base) else { return nil }
        let dereference = ExprNode(kind: .dereference)
        let baseOnly = [dereference, ExprNode(kind: .register, symbol: base, parentIndex: 0)]
        // Post-index: the text form is two operands, `[base]` and the increment.
        if memory.indexing == .postIndex {
            if let index = memory.index {
                guard let spelling = registerSpelling(index) else { return nil }
                return [baseOnly, [ExprNode(kind: .register, symbol: spelling)]]
            }
            return [baseOnly, [ExprNode(kind: .immediateInt, immediate: UInt64(bitPattern: memory.displacement))]]
        }
        guard let index = memory.index else {
            if memory.displacement == 0, presentation.omitZeroOffset { return [baseOnly] }
            return [[dereference, ExprNode(kind: .op, symbol: "+", parentIndex: 0),
                     ExprNode(kind: .register, symbol: base, parentIndex: 1),
                     ExprNode(kind: .immediateInt, immediate: UInt64(bitPattern: memory.displacement), parentIndex: 1)]]
        }
        guard let indexSpelling = registerSpelling(index) else { return nil }
        var nodes = [dereference, ExprNode(kind: .op, symbol: "+", parentIndex: 0),
                     ExprNode(kind: .register, symbol: base, parentIndex: 1)]
        if let modifier = memory.modifier, !(modifier.omitWhenZero && (modifier.amount ?? 0) == 0) {
            let shifted = modified(ExprNode(kind: .register, symbol: indexSpelling), modifier)
            let offset = nodes.count
            for var node in shifted {
                node.parentIndex = node.parentIndex.map { $0 + offset } ?? 1
                nodes.append(node)
            }
        } else {
            nodes.append(ExprNode(kind: .register, symbol: indexSpelling, parentIndex: 1))
        }
        return [nodes]
    }
}

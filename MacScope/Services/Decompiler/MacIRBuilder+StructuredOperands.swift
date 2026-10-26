import Foundation

public extension InstructionOperands {
    /// DP04 A3 gate shared by every consumer: a complete sidecar whose rendering is
    /// exactly the row's text. Only then may typed operands replace text parsing.
    func rendersExactly(mnemonic: String, operands: String) -> Bool {
        guard coverage == .complete,
              let rendered = ARM64OperandRenderer.render(self, legacyMnemonic: mnemonic, legacyOperands: operands)
        else { return false }
        return rendered.mnemonic.lowercased() == mnemonic.lowercased() && rendered.operands == operands
    }
}

/// DP04 A3: consume the decoder's typed operand sidecar where it is complete.
/// A row's typed memory operand is trusted only when its whole envelope renders
/// back to exactly the row's text, so typed and text lowering cannot disagree;
/// otherwise every consumer keeps the legacy text path.
extension MacIRBuilder {
    /// The single memory operand of `source`'s complete sidecar, or nil.
    static func typedMemoryOperand(of source: MacIRSourceSpan) -> InstructionOperands.Memory? {
        guard let sidecar = source.structuredOperands,
              sidecar.rendersExactly(mnemonic: source.mnemonic, operands: source.operands) else { return nil }
        let memories = sidecar.operands.compactMap { operand -> InstructionOperands.Memory? in
            if case let .memory(memory) = operand { return memory }
            return nil
        }
        return memories.count == 1 ? memories[0] : nil
    }

    static func registerName(_ register: InstructionOperands.Register) -> String? {
        guard register.bank == .general, register.arrangement == nil, register.lane == nil else { return nil }
        switch register.role {
        case .stackPointer: return register.width == 64 ? "sp" : "wsp"
        case .zero: return register.width == 64 ? "xzr" : "wzr"
        case .ordinary:
            guard (0...30).contains(register.index), [32, 64].contains(register.width) else { return nil }
            return "\(register.width == 64 ? "x" : "w")\(register.index)"
        }
    }

    /// The address a typed memory operand names, matching `memoryValue(for:)`'s
    /// text lowering case for case. Nil means "use the text path".
    static func structuredMemoryValue(_ memory: InstructionOperands.Memory, state: BuilderState) -> MacIRValue? {
        guard let base = registerName(memory.base), base != "wsp", memory.base.width == 64 else { return nil }
        // Post-index addresses the old base; offset and pre-index add the displacement.
        let offset: Int64 = memory.indexing == .postIndex ? 0 : memory.displacement
        guard let index = memory.index else {
            if base == "sp", !state.hasExplicitStackWriteback {
                return .stackSlot(offset: state.stackBaseOffset(for: base) + offset)
            }
            if base == "x29", let frameBase = state.knownStackBaseOffset(for: base) {
                return .stackSlot(offset: frameBase + offset)
            }
            let baseValue = state.readRegister(base)
            return offset == 0 ? baseValue : .binaryExpression(op: "+", left: baseValue, right: .immediate(offset))
        }
        // Register post-index addresses the old base; the index only updates it.
        if memory.indexing == .postIndex { return state.readRegister(base) }
        guard let indexName = registerName(index) else { return nil }
        let rawIndex = state.readRegister(indexName)
        let indexValue: MacIRValue = switch memory.modifier?.kind {
        case .uxtw?: .unary(op: "(uint64_t)", value: .unary(op: "(uint32_t)", value: rawIndex))
        case .sxtw?: .unary(op: "(int64_t)", value: .unary(op: "(int32_t)", value: rawIndex))
        default: rawIndex
        }
        let shift = Int64(memory.modifier?.amount ?? 0)
        let scaled: MacIRValue = shift == 0
            ? indexValue : .binaryExpression(op: "<<", left: indexValue, right: .immediate(shift))
        return .binaryExpression(op: "+", left: state.readRegister(base), right: scaled)
    }

    /// DP04 A3 (SIMD structure memory, #715 frames): whether the row's complete typed
    /// sidecar (#712) names exactly these registers, element width, lane and memory
    /// operand. The frames decode the instruction word themselves; this replaces the
    /// rendered-text comparison as their confirmation when a sidecar is present.
    static func typedStructureOperandsMatch<Row: DecompilerInstructionRow>(
        _ row: Row, vectorIndices: [Int], elementBits: Int, vectorBits: Int?, lane: Int?,
        base: Int, postIndex: Bool, incrementRegister: Int?, immediateStride: Int
    ) -> Bool {
        guard let sidecar = row.structuredOperands,
              sidecar.rendersExactly(mnemonic: row.mnemonic, operands: row.operands),
              sidecar.operands.count == 2,
              case let .registerList(registers) = sidecar.operands[0],
              case let .memory(memory) = sidecar.operands[1],
              registers.map(\.index) == vectorIndices,
              registers.allSatisfy({ register in
                  register.bank == .simd && register.arrangement?.elementWidth == elementBits
                      && register.lane == lane
                      && (lane != nil || register.arrangement?.laneCount == vectorBits.map { $0 / elementBits })
              }),
              memory.base.index == base, (base == 31) == (memory.base.role == .stackPointer),
              memory.modifier == nil else { return false }
        guard postIndex else { return memory.indexing == .offset && memory.index == nil && memory.displacement == 0 }
        guard memory.indexing == .postIndex else { return false }
        if let incrementRegister { return memory.index?.index == incrementRegister && memory.displacement == 0 }
        return memory.index == nil && memory.displacement == Int64(immediateStride)
    }
}

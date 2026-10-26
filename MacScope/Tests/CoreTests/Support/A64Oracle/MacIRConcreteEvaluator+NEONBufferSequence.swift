import Foundation
@testable import MacScope

extension MacIRConcreteEvaluator {
    /// Consume one bounded architectural instruction, not arbitrary middle slices.
    /// All framing, addresses and source bytes are staged before changing state.
    /// DOT31 remains the only transfer implementation. Its reads equal the staged
    /// snapshots because stores cannot change vector SSA and loads cannot change
    /// memory in this nonconcurrent successful-effects model; verify that invariant.
    mutating func executeNEONBufferSequence(_ instructions: [MacIRInstruction], start: Int,
                                           nextMemorySequence: Int) throws -> Int {
        guard let first = instructions[start].neonBufferSequence, first.ordinal == 0 else {
            throw Failure.unsupported("NEON sequence must start at effect zero")
        }
        let plan = first.sequence, count = plan.effectCount
        guard plan.firstMemorySequence == nextMemorySequence,
              count <= instructions.count - start else { throw Failure.unsupported("NEON sequence framing") }
        for ordinal in 0..<count {
            let instruction = instructions[start + ordinal]
            guard instruction.neonScalarVariableShift == nil, instruction.neonWiderChannelMemory == nil, instruction.neonMultiChannelLane == nil, instruction.neonWiderMultiChannelLane == nil, instruction.neonWiderMultiChannelReplicate == nil, instruction.neonScalarShiftCompilerComposition == nil, instruction.neonScalarMaskSelection == nil, instruction.neonScalarIntegerComparison == nil, instruction.neonMultiChannelReplicate == nil, instruction.neonFourChannelMemory == nil, instruction.source.address == instructions[start].source.address,
                  instruction.neonBufferSequence == .init(sequence: plan, ordinal: ordinal),
                  instruction.operation == plan.operation(ordinal),
                  instruction.neonBitView == nil, instruction.neonLogical == nil,
                  instruction.neonExtract == nil, instruction.neonPermutation == nil,
                  instruction.neonModular == nil, instruction.neonComparison == nil,
                  instruction.neonTableLookup == nil, instruction.scalarFP == nil,
                  instruction.returnTarget == nil else { throw Failure.unsupported("NEON sequence effect shape/order") }
            if ordinal < plan.vectors.count {
                guard instruction.neonBufferMemory == plan.memory(ordinal),
                      instruction.memoryAccess == MacIRMemoryAccess(byteWidth: 16) else {
                    throw Failure.unsupported("NEON sequence typed transfer")
                }
            } else if instruction.neonBufferMemory != nil || instruction.memoryAccess != nil {
                throw Failure.unsupported("NEON sequence writeback is not a memory effect")
            }
        }
        let old = try evaluate(plan.oldBase)
        guard old.width == 64, old.kind != .float else { throw Failure.unsupported("NEON sequence base width") }
        let updated = old.bits &+ UInt64(bitPattern: plan.delta)
        let address = plan.mode == .postIndex ? old.bits : updated
        guard address <= UInt64.max - UInt64(plan.vectors.count * 16 - 1) else {
            throw Failure.unsupported("NEON sequence wrapping transfer span")
        }
        let addresses = (0..<plan.vectors.count).map { address + UInt64($0 * 16) }
        let snapshots: [Scalar]
        if plan.effect == .store {
            snapshots = try plan.vectors.map { try readNEONRegister($0) }
        } else {
            snapshots = addresses.map { address in
                let bytes = (0..<16).map { state.byte(at: address + UInt64($0)) }
                func half(_ start: Int) -> UInt64 { (0..<8).reduce(0) { $0 | UInt64(bytes[start + $1]) << ($1 * 8) } }
                return .init(bits: half(0), width: 128, kind: .unsigned, high: half(8))
            }
        }
        for ordinal in plan.vectors.indices {
            let memory = plan.memory(ordinal)
            guard try evaluate(memory.base).bits == addresses[ordinal] else {
                throw Failure.unsupported("NEON sequence base snapshot changed")
            }
            if plan.effect == .store {
                guard try readNEONRegister(plan.vectors[ordinal]) == snapshots[ordinal] else {
                    throw Failure.unsupported("NEON sequence store snapshot changed")
                }
            }
            try executeNEONBufferMemory(memory, operation: instructions[start + ordinal].operation,
                                        memoryAccess: instructions[start + ordinal].memoryAccess)
            if plan.effect == .load {
                guard try readNEONRegister(plan.vectors[ordinal]) == snapshots[ordinal] else {
                    throw Failure.unsupported("NEON sequence load snapshot changed")
                }
            }
        }
        // The validated explicit assign is executed once from the staged update,
        // never from the second address and never before the memory effects.
        if let destination = plan.baseDestination {
            try write(destination, .int(updated, width: 64, signed: false))
        }
        return plan.vectors.count
    }
}

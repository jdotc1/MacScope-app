import Foundation
#if canImport(MacScope)
@testable import MacScope
#endif

extension MacIRConcreteEvaluator {
    /// A structure-lane transfer is one typed transaction even though each
    /// vector has its own IR commit. Check every ordinal before evaluating it.
    func validateNEONStructureLaneMemory(_ list: [MacIRInstruction]) throws {
        guard list.contains(where: { $0.neonStructureLaneMemory != nil }) else { return }
        guard list.count <= 193 else { throw Failure.unsupported("NEON structure-lane frame budget") }
        var position = 0, sequence = 0, byteSequence = 0
        while position < list.count {
            let instruction = list[position]
            if let step = instruction.neonStructureLaneMemory {
                let frame = step.frame
                guard step.ordinal == 0, frame.frameSequence == sequence,
                      frame.firstByteSequence == byteSequence,
                      frame.effectCount <= list.count - position else {
                    throw Failure.unsupported("NEON structure-lane framing/order")
                }
                for ordinal in 0..<frame.effectCount {
                    let effect = list[position + ordinal]
                    try validateStructureLaneExclusive(effect)
                    guard effect.source.address == instruction.source.address,
                          effect.neonStructureLaneMemory == .init(frame: frame, ordinal: ordinal),
                          frame.matches(effect.operation, ordinal: ordinal),
                          effect.returnTarget == nil else {
                        throw Failure.unsupported("NEON structure-lane effect shape")
                    }
                }
                sequence += 1
                byteSequence += frame.byteCount
                position += frame.effectCount
            } else {
                try validateStructureLaneExclusive(instruction)
                switch instruction.operation {
                case .returnValue(nil) where position == list.count - 1: break
                case let .returnValue(.some(.unknown(marker)))
                    where position == list.count - 1
                        && marker == MacIRIndirectTargetResolution.unresolvedReturnContractMarker: break
                case .intrinsic(nil, "nop", let arguments) where arguments.isEmpty: break
                default: throw Failure.unsupported("NEON structure-lane untyped effect")
                }
                position += 1
            }
        }
    }

    private func validateStructureLaneExclusive(_ instruction: MacIRInstruction) throws {
        guard instruction.memoryAccess == nil, instruction.neonLaneMemory == nil,
              instruction.neonInterleavedMemory == nil, instruction.neonContiguousGroup == nil,
              instruction.neonBufferMemory == nil, instruction.neonIndexedMemory == nil,
              instruction.neonBroadcastMemory == nil, instruction.neonFourChannelMemory == nil,
              instruction.neonMultiChannelLane == nil, instruction.neonWiderMultiChannelLane == nil,
              instruction.neonWiderChannelMemory == nil else {
            throw Failure.unsupported("NEON structure-lane family conflict")
        }
    }

    mutating func executeNEONStructureLaneMemory(_ frame: MacIRNEONStructureLaneMemory) throws {
        let base = try evaluate(frame.oldBase)
        guard base.width == 64, base.kind != .float,
              base.bits <= UInt64.max - UInt64(frame.byteCount - 1) else {
            throw Failure.unsupported("NEON structure-lane span/base")
        }
        // Rm may equal Rn; all inputs are read before any vector or base write.
        let increment: UInt64
        if let post = frame.registerPost {
            let captured = try evaluate(post.oldIncrement)
            guard captured.width == post.carrierWidth, captured.kind != .float else {
                throw Failure.unsupported("NEON structure-lane register-post increment")
            }
            increment = captured.bits
        } else {
            increment = UInt64(frame.fixedPostDelta)
        }
        let snapshots = try frame.oldVectors.map { try readNEONRegister($0) }
        guard snapshots.allSatisfy({ $0.width == 128 }) else {
            throw Failure.unsupported("NEON structure-lane physical128 snapshot")
        }
        var vectors = snapshots.map { vector in
            (0..<16).map { byte in
                UInt8(truncatingIfNeeded: (byte < 8 ? vector.bits : vector.high) >> ((byte % 8) * 8))
            }
        }
        if frame.effect == .load {
            for byte in frame.orderedBytes {
                vectors[byte.vector][byte.lane] = state.byte(at: base.bits + UInt64(byte.offset))
            }
            for index in frame.oldVectors.indices {
                func half(_ start: Int) -> UInt64 {
                    (0..<8).reduce(0) { $0 | UInt64(vectors[index][start + $1]) << ($1 * 8) }
                }
                try writeNEONRegister(frame.destinations[index],
                    .init(bits: half(0), width: 128, kind: .unsigned, high: half(8)))
            }
        } else {
            for byte in frame.orderedBytes {
                state.setByte(vectors[byte.vector][byte.lane], at: base.bits + UInt64(byte.offset))
            }
        }
        if let destination = frame.baseDestination {
            try write(destination, .int(base.bits &+ increment, width: 64, signed: false))
        }
    }

    /// Validate the entire typed list before payloads, including delayed-base
    /// interiors, exact partial accesses, both ordinal units and current SSA.
    /// Dynamic span checks remain per frame, not a transaction over the function.
    func validateNEONLaneMemory(_ list: [MacIRInstruction]) throws {
        guard !list.contains(where: { $0.neonLaneCoefficientProduct != nil || $0.neonReplicatedIndexedProduct != nil }) else { throw Failure.unsupported("replicated product marker in standalone family") }
        guard list.contains(where: { $0.neonLaneMemory != nil }) else { return }
        guard list.count <= 127, let last = list.last, case .returnValue(nil) = last.operation else { throw Failure.unsupported("lane budget/terminal return") }
        var position = 0, sequence = 0, byteSequence = 0
        var vectors: [String:Int] = [:], bases: [String:Int] = [:]
        func vectorRead(_ value: MacIRValue) throws {
            guard case let .register(name, version) = value, let index = A64MachineState.vectorIndex(name),
                  name == "v\(index)", version == vectors[name,default:0] else { throw Failure.unsupported("lane current physical128 snapshot") }
        }
        func baseRead(_ value: MacIRValue, name: String) throws {
            switch value {
            case let .register(n,v): guard n == name, v == bases[name,default:0] else { throw Failure.unsupported("lane current base") }
            case let .argument(binding):
                guard binding.kind == .gpr, binding.value >= 0, binding.value < 8,
                      name == "x\(binding.value)", bases[name,default:0] == 0 else { throw Failure.unsupported("lane argument base") }
            default: throw Failure.unsupported("lane base shape")
            }
        }
        func exclusive(_ i: MacIRInstruction) throws {
            guard i.neonScalarVariableShift == nil, i.neonWiderChannelMemory == nil, i.neonMultiChannelLane == nil, i.neonWiderMultiChannelLane == nil, i.neonWiderMultiChannelReplicate == nil, i.neonScalarShiftCompilerComposition == nil, i.neonScalarMaskSelection == nil, i.neonScalarIntegerComparison == nil, i.neonMultiChannelReplicate == nil else { throw Failure.unsupported("new82 foreign metadata exclusion") }
            guard i.neonBroadcastMemory == nil, i.neonBitCount == nil, i.neonOrderConversion == nil,
                  i.neonStructureLaneMemory == nil, i.neonInterleavedMemory == nil, i.neonIndexedMemory == nil, i.neonBufferMemory == nil,
                  i.neonBufferSequence == nil, i.neonBitView == nil, i.neonReduction == nil,
                  i.neonPacking == nil, i.neonImmediate == nil, i.neonMultiply == nil,
                  i.neonShiftInsert == nil, i.neonExtract == nil, i.neonPermutation == nil,
                  i.neonModular == nil, i.neonComparison == nil, i.neonTableLookup == nil,
                  i.neonLogical == nil, i.scalarFP == nil else { throw Failure.unsupported("lane family union") }
        }
        while position < list.count {
            let i = list[position]; try exclusive(i)
            if let step = i.neonLaneMemory {
                let f = step.frame
                guard step.ordinal == 0, f.frameSequence == sequence, f.firstByteSequence == byteSequence,
                      f.effectCount <= list.count-position else { throw Failure.unsupported("lane framing/order") }
                for ordinal in 0..<f.effectCount {
                    let e = list[position+ordinal]; try exclusive(e)
                    guard e.neonLaneMemory == .init(frame:f,ordinal:ordinal), e.source.address == i.source.address,
                          f.matches(e.operation,ordinal:ordinal), e.returnTarget == nil,
                          e.memoryAccess == (ordinal == 0 ? MacIRMemoryAccess(byteWidth:f.byteCount) : nil) else {
                        throw Failure.unsupported("lane commit/access shape")
                    }
                }
                try baseRead(f.oldBase,name:f.baseRegister); try vectorRead(f.oldVector)
                if let d = f.destination, case let .register(name,version) = d { vectors[name] = version }
                if let b = f.baseDestination, case let .register(name,version) = b { bases[name] = version }
                sequence += 1; byteSequence += f.byteCount; position += f.effectCount; continue
            }
            guard i.memoryAccess == nil else { throw Failure.unsupported("lane untyped memory") }
            switch i.operation {
            case .returnValue(nil) where position == list.count-1:
                guard let target = i.returnTarget else { throw Failure.unsupported("lane return target") }
                try baseRead(target,name:"x30")
            case .intrinsic(nil,"nop",let args) where args.isEmpty && i.returnTarget == nil: break
            default: throw Failure.unsupported("lane untyped effect")
            }
            position += 1
        }
    }
    mutating func executeNEONLaneMemory(_ frame: MacIRNEONLaneMemory) throws {
        let base = try evaluate(frame.oldBase), old = try readNEONRegister(frame.oldVector)
        guard base.width == 64, base.kind != .float,
              base.bits <= UInt64.max-UInt64(frame.byteCount-1), old.width == 128 else {
            throw Failure.unsupported("lane exact span/base/physical128 source")
        }
        // Snapshot the complete physical vector before any memory/vector/base write.
        var bytes = (0..<16).map { n in UInt8(truncatingIfNeeded:(n < 8 ? old.bits : old.high) >> ((n%8)*8)) }
        if frame.effect == .load {
            for n in 0..<frame.byteCount { bytes[frame.vectorByteOffset+n] = state.byte(at:base.bits+UInt64(n)) }
            func half(_ start: Int) -> UInt64 { (0..<8).reduce(0) { $0 | UInt64(bytes[start+$1]) << ($1*8) } }
            try writeNEONRegister(frame.destination!, .init(bits:half(0),width:128,kind:.unsigned,high:half(8)))
        } else {
            for n in 0..<frame.byteCount { state.setByte(bytes[frame.vectorByteOffset+n],at:base.bits+UInt64(n)) }
        }
        if let d = frame.baseDestination { try write(d,.int(base.bits &+ UInt64(frame.fixedPostDelta),width:64,signed:false)) }
    }
}

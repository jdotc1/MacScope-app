import Foundation
#if canImport(MacScope)
@testable import MacScope
#endif

extension MacIRConcreteEvaluator {
    /// Validate every frame, including interior commit steps, before any payload.
    /// Dynamic addresses and bytes are checked per frame, not transactionally
    /// across the function. An earlier successful frame is not rolled back.
    func validateNEONInterleavedMemory(_ list: [MacIRInstruction]) throws {
        guard !list.contains(where: { $0.neonLaneCoefficientProduct != nil || $0.neonReplicatedIndexedProduct != nil }) else { throw Failure.unsupported("replicated product marker in standalone family") }
        guard list.contains(where: { $0.neonInterleavedMemory != nil }) else { return }
        guard list.count <= 193 else { throw Failure.unsupported("NEON interleaved frame budget") }
        var position = 0, nextByte = 0
        while position < list.count {
            let instruction = list[position]
            if let step = instruction.neonInterleavedMemory {
                let frame = step.frame
                guard step.ordinal == 0, frame.firstByteSequence == nextByte,
                      frame.effectCount <= list.count - position else { throw Failure.unsupported("NEON interleaved framing/order") }
                for ordinal in 0..<frame.effectCount {
                    let i = list[position+ordinal]
                    try validateInterleavedExclusive(i)
                    guard i.source.address == instruction.source.address,
                          i.neonInterleavedMemory == .init(frame: frame, ordinal: ordinal),
                          frame.matches(i.operation, ordinal: ordinal), i.returnTarget == nil else {
                        throw Failure.unsupported("NEON interleaved frame shape")
                    }
                }
                nextByte += frame.byteCount; position += frame.effectCount
            } else {
                try validateInterleavedExclusive(instruction)
                switch instruction.operation {
                case .returnValue(nil):
                    guard position == list.count-1 else { throw Failure.unsupported("NEON interleaved early return") }
                case .intrinsic(nil, "nop", let args) where args.isEmpty:
                    guard instruction.returnTarget == nil else { throw Failure.unsupported("NEON interleaved NOP return") }
                default: throw Failure.unsupported("NEON interleaved untyped effect")
                }
                position += 1
            }
        }
    }
    private func validateInterleavedExclusive(_ i: MacIRInstruction) throws {
        guard i.neonStructureLaneMemory == nil, i.neonScalarVariableShift == nil, i.neonWiderChannelMemory == nil, i.neonMultiChannelLane == nil, i.neonWiderMultiChannelLane == nil, i.neonWiderMultiChannelReplicate == nil, i.neonScalarShiftCompilerComposition == nil, i.neonScalarMaskSelection == nil, i.neonScalarIntegerComparison == nil, i.neonMultiChannelReplicate == nil, i.neonFourChannelMemory == nil, i.memoryAccess == nil, i.neonIndexedMemory == nil, i.neonBufferMemory == nil,
              i.neonBufferSequence == nil, i.neonBitView == nil, i.neonReduction == nil,
              i.neonPacking == nil, i.neonImmediate == nil, i.neonMultiply == nil,
              i.neonShiftInsert == nil, i.neonExtract == nil, i.neonPermutation == nil,
              i.neonModular == nil, i.neonComparison == nil, i.neonTableLookup == nil,
              i.neonLogical == nil, i.scalarFP == nil else { throw Failure.unsupported("NEON interleaved family/access conflict") }
    }
    mutating func executeNEONInterleavedMemory(_ frame: MacIRNEONInterleavedMemory) throws {
        let old = try evaluate(frame.oldBase)
        guard old.width == 64, old.kind != .float,
              old.bits <= UInt64.max - UInt64(frame.byteCount-1) else {
            throw Failure.unsupported("NEON interleaved combined span/base")
        }
        // Rm may be Rn. Capture its old value before any architectural write.
        let increment: UInt64
        if let post = frame.registerPost {
            let captured = try evaluate(post.oldIncrement)
            guard captured.width == post.carrierWidth, captured.kind != .float else {
                throw Failure.unsupported("NEON interleaved register-post increment")
            }
            increment = captured.bits
        } else {
            increment = UInt64(frame.fixedPostDelta)
        }
        let updated = old.bits &+ increment
        // Source snapshots and complete combined span precede all payload writes.
        var payloads = [[UInt8]](repeating: [UInt8](repeating: 0, count: 16), count: frame.groupCount)
        if frame.effect == .store {
            let snapshots = try frame.vectors.map { try readNEONRegister($0) }
            guard snapshots.allSatisfy({ $0.width == 128 }) else {
                throw Failure.unsupported("NEON interleaved store physical128 snapshot")
            }
            for vector in 0..<frame.groupCount {
                for lane in 0..<frame.activeBytes {
                    let value = lane < 8 ? snapshots[vector].bits : snapshots[vector].high
                    payloads[vector][lane] = UInt8(truncatingIfNeeded: value >> ((lane%8)*8))
                }
            }
        } else {
            // Layout is supplied by the typed frame: LD1 lists are contiguous,
            // LD2–LD4 interleave whole elements. Inactive bytes remain zero.
            for byte in frame.orderedBytes {
                payloads[byte.vector][byte.lane] = state.byte(at: old.bits + UInt64(byte.offset))
            }
        }
        if frame.effect == .store {
            for byte in frame.orderedBytes {
                state.setByte(payloads[byte.vector][byte.lane], at: old.bits + UInt64(byte.offset))
            }
        } else {
            for vector in 0..<frame.groupCount {
                func half(_ start: Int) -> UInt64 {
                    (0..<8).reduce(0) { $0 | UInt64(payloads[vector][start+$1]) << ($1*8) }
                }
                try writeNEONRegister(frame.vectors[vector], .init(bits: half(0), width: 128, kind: .unsigned, high: half(8)))
            }
        }
        if let destination = frame.baseDestination {
            try write(destination, .int(updated, width: 64, signed: false))
        }
    }
}

import Foundation
#if canImport(MacScope)
@testable import MacScope
#endif

extension MacIRConcreteEvaluator {
    /// Inspect every effect before payload dispatch, including retained frame
    /// interiors. Only conversion plus ordinary31 Q memory is a new union.
    func validateNEONBitCount(_ instructions: [MacIRInstruction]) throws {
        guard !instructions.contains(where: { $0.neonLaneCoefficientProduct != nil || $0.neonReplicatedIndexedProduct != nil }) else { throw Failure.unsupported("replicated product marker in standalone family") }
        guard instructions.contains(where: { $0.neonBitCount != nil }) else { return }
        var ordinal = 0
        for i in instructions {
            guard i.neonScalarVariableShift == nil, i.neonWiderChannelMemory == nil, i.neonMultiChannelLane == nil, i.neonWiderMultiChannelLane == nil, i.neonWiderMultiChannelReplicate == nil, i.neonScalarShiftCompilerComposition == nil, i.neonScalarMaskSelection == nil, i.neonScalarIntegerComparison == nil, i.neonMultiChannelReplicate == nil else { throw Failure.unsupported("new82 foreign metadata exclusion") }
            guard i.neonOrderConversion == nil, i.neonInterleavedMemory == nil, i.neonIndexedMemory == nil,
                  i.neonBufferSequence == nil, i.neonBitView == nil, i.neonReduction == nil,
                  i.neonPacking == nil, i.neonImmediate == nil, i.neonMultiply == nil,
                  i.neonShiftInsert == nil, i.neonLogical == nil, i.neonExtract == nil,
                  i.neonPermutation == nil, i.neonModular == nil, i.neonComparison == nil,
                  i.neonTableLookup == nil, i.scalarFP == nil else { throw Failure.unsupported("NEON count family union") }
            if i.neonBitCount != nil {
                guard i.neonScalarVariableShift == nil, i.neonWiderChannelMemory == nil, i.neonMultiChannelLane == nil, i.neonWiderMultiChannelLane == nil, i.neonWiderMultiChannelReplicate == nil, i.neonScalarShiftCompilerComposition == nil, i.neonScalarMaskSelection == nil, i.neonScalarIntegerComparison == nil, i.neonMultiChannelReplicate == nil else { throw Failure.unsupported("new82 foreign metadata exclusion") }
                guard i.neonBufferMemory == nil, i.memoryAccess == nil, i.returnTarget == nil else { throw Failure.unsupported("NEON count competing metadata") }
                try validateCountShape(i.operation)
            } else if let memory = i.neonBufferMemory {
                guard memory.sequence == ordinal, i.memoryAccess == .init(byteWidth: 16), i.returnTarget == nil else { throw Failure.unsupported("NEON count memory ordinal/access") }
                switch (memory.effect, i.operation) {
                case let (.load, .load(destination, address)) where address == memory.address:
                    guard countCarrier(destination, minimum: 1) else { throw Failure.unsupported("NEON count load carrier") }
                case let (.store, .store(source, address)) where address == memory.address:
                    guard countCarrier(source, minimum: 0) else { throw Failure.unsupported("NEON count store carrier") }
                default: throw Failure.unsupported("NEON count memory shape")
                }
                ordinal += 1
            } else {
                guard i.memoryAccess == nil else { throw Failure.unsupported("NEON count untyped memory") }
                switch i.operation {
                case .returnValue(nil): break
                case .intrinsic(nil, "nop", let args) where args.isEmpty && i.returnTarget == nil: break
                default: throw Failure.unsupported("NEON count untyped effect")
                }
            }
        }
    }
    private func countCarrier(_ value: MacIRValue, minimum: Int) -> Bool {
        guard case let .register(name, version) = value, let n = A64MachineState.vectorIndex(name) else { return false }
        return name == "v\(n)" && version >= minimum
    }
    private func validateCountShape(_ operation: MacIROperation) throws {
        guard case let .intrinsic(destination?, _, arguments) = operation, arguments.count == 1,
              countCarrier(destination, minimum: 1), countCarrier(arguments[0], minimum: 0),
              case let .register(d, version) = destination, case let .register(n, sourceVersion) = arguments[0],
              d != n || sourceVersion < version else { throw Failure.unsupported("NEON count source snapshot/shape") }
    }
    mutating func executeNEONBitCount(_ descriptor: MacIRNEONBitCount, operation: MacIROperation) throws {
        try validateCountShape(operation)
        guard case let .intrinsic(destination?, _, arguments) = operation else { throw Failure.unsupported("NEON count intrinsic") }
        let source = try readNEONRegister(arguments[0])
        guard source.width == 128 else { throw Failure.unsupported("NEON count source width") }
        func byte(_ index: Int) -> UInt64 { ((index < 8 ? source.bits : source.high) >> (index % 8 * 8)) & 255 }
        var low: UInt64 = 0, high: UInt64 = 0
        let laneBits = descriptor.elementBytes * 8
        for position in stride(from: 0, to: descriptor.activeBytes, by: descriptor.elementBytes) {
            var lane: UInt64 = 0
            for index in 0..<descriptor.elementBytes { lane |= byte(position + index) << (index * 8) }
            let value: UInt64
            switch descriptor.kind {
            case .cnt:
                value = UInt64(lane.nonzeroBitCount)
            case .clz:
                value = UInt64(lane.leadingZeroBitCount - (64 - laneBits))
            case .cls:
                // Complement only the exact lane when its sign is one. This
                // avoids host signed overflow even at the minimum-sign endpoint.
                let mask = (UInt64(1) << laneBits) - 1
                let normalized = lane & (UInt64(1) << (laneBits - 1)) == 0 ? lane : lane ^ mask
                value = UInt64(normalized.leadingZeroBitCount - (64 - laneBits) - 1)
            }
            if position < 8 { low |= value << (position * 8) }
            else { high |= value << ((position - 8) * 8) }
        }
        // Inactive Q0 high half is zero, never old destination content.
        try writeNEONRegister(destination, .init(bits: low, width: 128, kind: .unsigned, high: high))
    }
}

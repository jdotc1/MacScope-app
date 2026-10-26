import Foundation
#if canImport(MacScope)
@testable import MacScope
#endif

extension MacIRConcreteEvaluator {
    /// Inspect every effect before payload dispatch, including retained frame
    /// interiors. Only conversion plus ordinary31 Q memory is a new union.
    func validateNEONOrderConversion(_ instructions: [MacIRInstruction]) throws {
        guard !instructions.contains(where: { $0.neonLaneCoefficientProduct != nil || $0.neonReplicatedIndexedProduct != nil }) else { throw Failure.unsupported("replicated product marker in standalone family") }
        guard instructions.contains(where: { $0.neonOrderConversion != nil }) else { return }
        var ordinal = 0
        for i in instructions {
            guard i.neonScalarVariableShift == nil, i.neonWiderChannelMemory == nil, i.neonMultiChannelLane == nil, i.neonWiderMultiChannelLane == nil, i.neonWiderMultiChannelReplicate == nil, i.neonScalarShiftCompilerComposition == nil, i.neonScalarMaskSelection == nil, i.neonScalarIntegerComparison == nil, i.neonMultiChannelReplicate == nil else { throw Failure.unsupported("new82 foreign metadata exclusion") }
            guard i.neonInterleavedMemory == nil, i.neonIndexedMemory == nil,
                  i.neonBufferSequence == nil, i.neonBitView == nil, i.neonReduction == nil,
                  i.neonPacking == nil, i.neonImmediate == nil, i.neonMultiply == nil,
                  i.neonShiftInsert == nil, i.neonLogical == nil, i.neonExtract == nil,
                  i.neonPermutation == nil, i.neonModular == nil, i.neonComparison == nil,
                  i.neonTableLookup == nil, i.scalarFP == nil else { throw Failure.unsupported("NEON order family union") }
            if i.neonOrderConversion != nil {
                guard i.neonScalarVariableShift == nil, i.neonWiderChannelMemory == nil, i.neonMultiChannelLane == nil, i.neonWiderMultiChannelLane == nil, i.neonWiderMultiChannelReplicate == nil, i.neonScalarShiftCompilerComposition == nil, i.neonScalarMaskSelection == nil, i.neonScalarIntegerComparison == nil, i.neonMultiChannelReplicate == nil else { throw Failure.unsupported("new82 foreign metadata exclusion") }
                guard i.neonBufferMemory == nil, i.memoryAccess == nil, i.returnTarget == nil else { throw Failure.unsupported("NEON order competing metadata") }
                try validateOrderShape(i.operation)
            } else if let memory = i.neonBufferMemory {
                guard memory.sequence == ordinal, i.memoryAccess == .init(byteWidth: 16), i.returnTarget == nil else { throw Failure.unsupported("NEON order memory ordinal/access") }
                switch (memory.effect, i.operation) {
                case let (.load, .load(destination, address)) where address == memory.address:
                    guard orderCarrier(destination, minimum: 1) else { throw Failure.unsupported("NEON order load carrier") }
                case let (.store, .store(source, address)) where address == memory.address:
                    guard orderCarrier(source, minimum: 0) else { throw Failure.unsupported("NEON order store carrier") }
                default: throw Failure.unsupported("NEON order memory shape")
                }
                ordinal += 1
            } else {
                guard i.memoryAccess == nil else { throw Failure.unsupported("NEON order untyped memory") }
                switch i.operation {
                case .returnValue(nil): break
                case .intrinsic(nil, "nop", let args) where args.isEmpty && i.returnTarget == nil: break
                default: throw Failure.unsupported("NEON order untyped effect")
                }
            }
        }
    }
    private func orderCarrier(_ value: MacIRValue, minimum: Int) -> Bool {
        guard case let .register(name, version) = value, let n = A64MachineState.vectorIndex(name) else { return false }
        return name == "v\(n)" && version >= minimum
    }
    private func validateOrderShape(_ operation: MacIROperation) throws {
        guard case let .intrinsic(destination?, _, arguments) = operation, arguments.count == 1,
              orderCarrier(destination, minimum: 1), orderCarrier(arguments[0], minimum: 0),
              case let .register(d, version) = destination, case let .register(n, sourceVersion) = arguments[0],
              d != n || sourceVersion < version else { throw Failure.unsupported("NEON order source snapshot/shape") }
    }
    mutating func executeNEONOrderConversion(_ descriptor: MacIRNEONOrderConversion, operation: MacIROperation) throws {
        try validateOrderShape(operation)
        guard case let .intrinsic(destination?, _, arguments) = operation else { throw Failure.unsupported("NEON order intrinsic") }
        let source = try readNEONRegister(arguments[0])
        guard source.width == 128 else { throw Failure.unsupported("NEON order source width") }
        func byte(_ index: Int) -> UInt64 { ((index < 8 ? source.bits : source.high) >> (index % 8 * 8)) & 255 }
        var low: UInt64 = 0, high: UInt64 = 0
        for position in 0..<descriptor.activeBytes {
            let value: UInt64
            if descriptor.kind == .rbit {
                let input = byte(position)
                value = (0..<8).reduce(UInt64(0)) { $0 | ((input >> $1) & 1) << (7 - $1) }
            } else {
                let group = descriptor.groupBytes, element = descriptor.elementBytes
                let groupStart = position / group * group
                let elementStart = (position % group) / element * element
                value = byte(groupStart + group - element - elementStart + position % element)
            }
            if position < 8 { low |= value << (position * 8) }
            else { high |= value << ((position - 8) * 8) }
        }
        // Inactive Q0 high half is zero, never old destination content.
        try writeNEONRegister(destination, .init(bits: low, width: 128, kind: .unsigned, high: high))
    }
}

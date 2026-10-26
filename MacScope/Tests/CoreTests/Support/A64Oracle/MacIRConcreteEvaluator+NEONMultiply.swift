import Foundation
@testable import MacScope

extension MacIRConcreteEvaluator {
    /// Preflight includes interior33 effects skipped by its frame consumer.
    func validateNEONMultiplyMetadata(_ instruction: MacIRInstruction) throws {
        guard instruction.neonMultiply != nil else { return }
        guard instruction.neonScalarVariableShift == nil, instruction.neonWiderChannelMemory == nil, instruction.neonMultiChannelLane == nil, instruction.neonWiderMultiChannelLane == nil, instruction.neonWiderMultiChannelReplicate == nil, instruction.neonMultiChannelReplicate == nil else { throw Failure.unsupported("new82 foreign metadata exclusion") }
        guard instruction.neonShiftInsert == nil, instruction.neonBufferSequence == nil,
              instruction.neonBufferMemory == nil, instruction.neonBitView == nil,
              instruction.neonLogical == nil, instruction.neonExtract == nil,
              instruction.neonPermutation == nil, instruction.neonModular == nil,
              instruction.neonComparison == nil, instruction.neonTableLookup == nil,
              instruction.scalarFP == nil, instruction.memoryAccess == nil,
              instruction.returnTarget == nil else { throw Failure.unsupported("NEON multiply conflicting metadata") }
    }
    mutating func executeNEONMultiply(_ descriptor: MacIRNEONMultiply, operation: MacIROperation) throws {
        guard case let .intrinsic(destination?, _, arguments) = operation,
              arguments.count == (descriptor.kind.readsDestination ? 3 : 2),
              case let .register(destinationName, version) = destination, version > 0,
              let index = A64MachineState.vectorIndex(destinationName), destinationName == "v\(index)" else { throw Failure.unsupported("NEON multiply operand shape") }
        for argument in arguments {
            guard case let .register(name, sourceVersion) = argument, sourceVersion >= 0,
                  let n = A64MachineState.vectorIndex(name), name == "v\(n)",
                  name != destinationName || sourceVersion < version else { throw Failure.unsupported("NEON multiply source snapshot") }
        }
        if descriptor.selectedLane != nil && descriptor.arrangement.laneBits == 16 {
            guard case let .register(name, _) = arguments[1], A64MachineState.vectorIndex(name)! < 16 else { throw Failure.unsupported("NEON multiply H source bank") }
        }
        if descriptor.kind.readsDestination {
            guard arguments[2] == .register(name: destinationName, version: version - 1) else { throw Failure.unsupported("NEON multiply old destination") }
        }
        let lhs = try readNEONRegister(arguments[0]), rhs = try readNEONRegister(arguments[1])
        let old = descriptor.kind.readsDestination ? try readNEONRegister(arguments[2]) : Scalar(bits: 0, width: 128, kind: .unsigned)
        guard lhs.width == 128, rhs.width == 128, old.width == 128 else { throw Failure.unsupported("NEON multiply input width") }
        let r = descriptor.evaluate(lhs: (lhs.bits, lhs.high), rhs: (rhs.bits, rhs.high), oldDestination: (old.bits, old.high))
        try writeNEONRegister(destination, Scalar(bits: r.low, width: 128, kind: .unsigned, high: r.high))
    }
}

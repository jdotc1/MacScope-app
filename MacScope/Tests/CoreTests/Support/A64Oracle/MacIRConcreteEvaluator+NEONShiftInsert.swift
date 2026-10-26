import Foundation
@testable import MacScope

extension MacIRConcreteEvaluator {
    /// Preflight the whole list, including interior33 effects skipped by run's
    /// frame consumer. No competing descriptor may silently win dispatch.
    func validateNEONShiftInsertMetadata(_ instruction: MacIRInstruction) throws {
        guard instruction.neonShiftInsert != nil else { return }
        guard instruction.neonScalarVariableShift == nil, instruction.neonWiderChannelMemory == nil, instruction.neonMultiChannelLane == nil, instruction.neonWiderMultiChannelLane == nil, instruction.neonWiderMultiChannelReplicate == nil, instruction.neonMultiChannelReplicate == nil else { throw Failure.unsupported("new82 foreign metadata exclusion") }
        guard instruction.neonBufferSequence == nil, instruction.neonBufferMemory == nil,
              instruction.neonBitView == nil, instruction.neonLogical == nil,
              instruction.neonExtract == nil, instruction.neonPermutation == nil,
              instruction.neonModular == nil, instruction.neonComparison == nil,
              instruction.neonTableLookup == nil, instruction.scalarFP == nil,
              instruction.memoryAccess == nil, instruction.returnTarget == nil else {
            throw Failure.unsupported("NEON shift conflicting metadata")
        }
    }
    mutating func executeNEONShiftInsert(_ descriptor: MacIRNEONShiftInsert, operation: MacIROperation) throws {
        guard case let .intrinsic(destination?, _, arguments) = operation,
              arguments.count == (descriptor.kind.readsDestination ? 2 : 1),
              case let .register(destinationName, version) = destination, version > 0,
              let index = A64MachineState.vectorIndex(destinationName), destinationName == "v\(index)" else {
            throw Failure.unsupported("NEON shift operand shape")
        }
        for argument in arguments {
            guard case let .register(name, sourceVersion) = argument, sourceVersion >= 0,
                  name != destinationName || sourceVersion < version else {
                throw Failure.unsupported("NEON shift source snapshot")
            }
        }
        if descriptor.kind.readsDestination {
            guard case let .register(name, oldVersion) = arguments[1], name == destinationName,
                  oldVersion == version - 1 else { throw Failure.unsupported("NEON insert old destination") }
        }
        let n = try readNEONRegister(arguments[0])
        let d = descriptor.kind.readsDestination ? try readNEONRegister(arguments[1]) : Scalar(bits: 0, width: 128, kind: .unsigned)
        guard n.width == 128, d.width == 128 else { throw Failure.unsupported("NEON shift input width") }
        let result = descriptor.evaluate(source: (n.bits, n.high), oldDestination: (d.bits, d.high))
        try writeNEONRegister(destination, Scalar(bits: result.low, width: 128, kind: .unsigned, high: result.high))
    }
}

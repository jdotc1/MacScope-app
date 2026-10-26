import Foundation
@testable import MacScope

extension MacIRConcreteEvaluator {
    /// Preflight every effect, including interior33 steps, before dispatch skips them.
    func validateNEONImmediateMetadata(_ i: MacIRInstruction) throws {
        guard i.neonImmediate != nil else { return }
        guard i.neonScalarVariableShift == nil, i.neonWiderChannelMemory == nil, i.neonMultiChannelLane == nil, i.neonWiderMultiChannelLane == nil, i.neonWiderMultiChannelReplicate == nil, i.neonMultiChannelReplicate == nil else { throw Failure.unsupported("new82 foreign metadata exclusion") }
        guard i.neonMultiply == nil, i.neonShiftInsert == nil, i.neonBufferSequence == nil,
              i.neonBufferMemory == nil, i.neonBitView == nil, i.neonLogical == nil,
              i.neonExtract == nil, i.neonPermutation == nil, i.neonModular == nil,
              i.neonComparison == nil, i.neonTableLookup == nil, i.scalarFP == nil,
              i.memoryAccess == nil, i.returnTarget == nil else { throw Failure.unsupported("NEON immediate conflicting metadata") }
    }
    mutating func executeNEONImmediate(_ d: MacIRNEONImmediate, operation: MacIROperation) throws {
        guard case let .intrinsic(destination?, _, args) = operation, args.isEmpty,
              case let .register(name, version) = destination, version > 0,
              let index = A64MachineState.vectorIndex(name), name == "v\(index)" else { throw Failure.unsupported("NEON immediate operand shape") }
        try writeNEONRegister(destination,Scalar(bits:d.low,width:128,kind:.unsigned,high:d.high))
    }
}

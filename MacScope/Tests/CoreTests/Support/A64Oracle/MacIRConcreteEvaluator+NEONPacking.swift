import Foundation
#if canImport(MacScope)
@testable import MacScope
#endif

extension MacIRConcreteEvaluator {
    /// Preflight all effects before frame dispatch can skip an interior effect.
    func validateNEONPackingMetadata(_ i: MacIRInstruction) throws {
        guard i.neonPacking != nil else { return }
        guard i.neonScalarVariableShift == nil, i.neonWiderChannelMemory == nil, i.neonMultiChannelLane == nil, i.neonWiderMultiChannelLane == nil, i.neonWiderMultiChannelReplicate == nil, i.neonMultiChannelReplicate == nil else { throw Failure.unsupported("new82 foreign metadata exclusion") }
        guard i.neonReduction == nil, i.neonImmediate == nil, i.neonMultiply == nil,
              i.neonShiftInsert == nil, i.neonBufferSequence == nil, i.neonBufferMemory == nil,
              i.neonBitView == nil, i.neonLogical == nil, i.neonExtract == nil,
              i.neonPermutation == nil, i.neonModular == nil, i.neonComparison == nil,
              i.neonTableLookup == nil, i.scalarFP == nil, i.memoryAccess == nil,
              i.returnTarget == nil else { throw Failure.unsupported("NEON packing conflicting metadata") }
    }
    mutating func executeNEONPacking(_ d: MacIRNEONPacking, operation: MacIROperation) throws {
        guard case let .intrinsic(destination?,_,args) = operation,
              args.count == (d.readsDestination ? 2 : 1),
              case let .register(name,version) = destination, version > 0,
              let index = A64MachineState.vectorIndex(name), name == "v\(index)" else {
            throw Failure.unsupported("NEON packing operand shape")
        }
        for argument in args {
            guard case let .register(sourceName,sourceVersion) = argument, sourceVersion >= 0,
                  let sourceIndex = A64MachineState.vectorIndex(sourceName), sourceName == "v\(sourceIndex)",
                  name != sourceName || sourceVersion < version else {
                throw Failure.unsupported("NEON packing source snapshot")
            }
        }
        if d.readsDestination {
            guard case let .register(oldName,oldVersion) = args[1], oldName == name, oldVersion == version-1 else {
                throw Failure.unsupported("NEON packing old destination")
            }
        }
        let source = try readNEONRegister(args[0])
        let old = d.readsDestination ? try readNEONRegister(args[1]) : Scalar(bits:0,width:128,kind:.unsigned)
        guard source.width == 128, old.width == 128 else { throw Failure.unsupported("NEON packing source width") }
        let value = d.evaluate(source:(source.bits,source.high),oldDestination:(old.bits,old.high))
        try writeNEONRegister(destination,.init(bits:value.low,width:128,kind:.unsigned,high:value.high))
    }
}

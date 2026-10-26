import Foundation
@testable import MacScope

extension MacIRConcreteEvaluator {
    func validateNEONReductionMetadata(_ i: MacIRInstruction) throws {
        guard i.neonReduction != nil else { return }
        guard i.neonScalarVariableShift == nil, i.neonWiderChannelMemory == nil, i.neonMultiChannelLane == nil, i.neonWiderMultiChannelLane == nil, i.neonWiderMultiChannelReplicate == nil, i.neonMultiChannelReplicate == nil else { throw Failure.unsupported("new82 foreign metadata exclusion") }
        guard i.neonImmediate == nil, i.neonMultiply == nil, i.neonShiftInsert == nil,
              i.neonBufferSequence == nil, i.neonBufferMemory == nil, i.neonBitView == nil,
              i.neonLogical == nil, i.neonExtract == nil, i.neonPermutation == nil,
              i.neonModular == nil, i.neonComparison == nil, i.neonTableLookup == nil,
              i.scalarFP == nil, i.memoryAccess == nil, i.returnTarget == nil else {
            throw Failure.unsupported("NEON reduction conflicting metadata")
        }
    }
    mutating func executeNEONReduction(_ d: MacIRNEONReduction, operation: MacIROperation) throws {
        guard case let .intrinsic(destination?,_,arguments) = operation, arguments.count == 1,
              case let .register(sourceName,sourceVersion) = arguments[0], sourceVersion >= 0,
              let sourceIndex = A64MachineState.vectorIndex(sourceName), sourceName == "v\(sourceIndex)",
              case let .register(name,version) = destination else { throw Failure.unsupported("NEON reduction operand shape") }
        if d.isExtraction {
            guard MacIRBuilder.bitViewGPR(name,width:d.gprBits) != nil,
                  (name == "wzr" || name == "xzr") ? version == 0 : version > 0 else { throw Failure.unsupported("NEON extraction destination") }
        } else {
            guard let n = A64MachineState.vectorIndex(name), name == "v\(n)", version > 0 else { throw Failure.unsupported("NEON reduction destination") }
        }
        guard name != sourceName || sourceVersion < version else { throw Failure.unsupported("NEON reduction aliased source version") }
        let source = try readNEONRegister(arguments[0])
        guard source.width == 128 else { throw Failure.unsupported("NEON reduction source width") }
        let mask: UInt64 = d.elementBits == 64 ? .max : (UInt64(1)<<d.elementBits)-1
        func lane(_ i:Int) -> UInt64 {
            let offset = i*d.elementBits
            return ((offset < 64 ? source.bits : source.high) >> (offset % 64)) & mask
        }
        func signed(_ bits:UInt64) -> Int64 {
            if d.elementBits == 64 { return Int64(bitPattern:bits) }
            return bits & (UInt64(1)<<(d.elementBits-1)) == 0 ? Int64(bits) : Int64(bits) - (Int64(1)<<d.elementBits)
        }
        let bits: UInt64
        switch d.kind {
        case .umov: bits = lane(d.lane)
        case .smov: bits = UInt64(bitPattern:signed(lane(d.lane)))
        case .addv, .uaddlv: bits = (0..<d.inputLanes).reduce(UInt64(0)) { $0 &+ lane($1) }
        case .saddlv: bits = UInt64(bitPattern:(0..<d.inputLanes).reduce(Int64(0)) { $0 + signed(lane($1)) })
        case .uminv: bits = (0..<d.inputLanes).map(lane).min()!
        case .umaxv: bits = (0..<d.inputLanes).map(lane).max()!
        case .sminv: bits = UInt64(bitPattern:(0..<d.inputLanes).map { signed(lane($0)) }.min()!)
        case .smaxv: bits = UInt64(bitPattern:(0..<d.inputLanes).map { signed(lane($0)) }.max()!)
        }
        let outputMask: UInt64 = d.outputBits == 64 ? .max : (UInt64(1)<<d.outputBits)-1
        if d.isExtraction {
            if name == "wzr" || name == "xzr" { return } // No architecture or SSA mutation.
            try write(destination,.int(bits & outputMask,width:d.gprBits,signed:false))
        } else {
            // B/H/S/D writes clear every physical bit outside their scalar result.
            try writeNEONRegister(destination,.init(bits:bits & outputMask,width:128,kind:.unsigned,high:0))
        }
    }
}

import Foundation
#if canImport(MacScope)
@testable import MacScope
#endif

extension MacIRConcreteEvaluator {
    /// The only permission to bypass the incompatible standalone52/54/55
    /// validators is a successful complete certificate. Inspect EVERY effect,
    /// including interiors of any attempted foreign frame, before any dispatch.
    func validateNEONGroupWidenNarrow(_ list:[MacIRInstruction]) throws -> MacIRNEONGroupWidenNarrow? {
        guard !list.contains(where: { $0.neonLaneCoefficientProduct != nil || $0.neonReplicatedIndexedProduct != nil }) else { throw Failure.unsupported("replicated product marker in standalone family") }
        guard list.contains(where:{ $0.neonContiguousGroup != nil }),
              list.contains(where:{ $0.neonWideningPairwise != nil || $0.neonShiftNarrow != nil }) else { return nil }
        guard list.count <= 316,list.last?.operation == .returnValue(nil),
              Set(list.map(\.id)).count == list.count,
              !function.parameters.contains(where:{
                  switch $0.abiLocation { case .simd,.entryStack:return true;default:return false }
              }) else { throw Failure.unsupported("group widen narrow bound/identity/formals/terminal") }
        var position=0,sequence=0,byteSequence=0
        var entries:[MacIRNEONGroupWidenNarrow.Entry]=[],vectors:[String:Int]=[:],bases:[String:Int]=[:]
        func vector(_ value:MacIRValue,write:Bool) throws -> String {
            guard case let .register(name,version)=value,let n=A64MachineState.vectorIndex(name),name == "v\(n)",
                  version == vectors[name,default:0]+(write ? 1:0) else { throw Failure.unsupported("group widen narrow latest physical128 vector") }
            if write { vectors[name]=version };return name
        }
        func base(_ value:MacIRValue,name:String) throws {
            guard let n=A64MachineState.gprIndex(name),n < 31,name == "x\(n)" else { throw Failure.unsupported("group widen narrow ordinary base") }
            switch value {
            case let .register(actual,version):
                guard actual == name,version == bases[name,default:0],
                      version > 0 || !function.parameters.contains(where:{ $0.register == name && $0.bindingID != nil }) else { throw Failure.unsupported("group widen narrow current base/formal") }
            case let .argument(binding):
                guard binding.kind == .gpr,(0..<8).contains(binding.value),name == "x\(binding.value)",bases[name,default:0] == 0,
                      function.parameters.filter({ $0.bindingID == binding }).count == 1,
                      function.parameters.first(where:{ $0.bindingID == binding })?.abiLocation == .gpr(index:binding.value,carrierWidth:64) else { throw Failure.unsupported("group widen narrow unbound/narrow base") }
            default:throw Failure.unsupported("group widen narrow base shape")
            }
        }
        func exclusive(_ i:MacIRInstruction) throws {
            guard i.neonScalarVariableShift == nil, i.neonWiderChannelMemory == nil, i.neonMultiChannelLane == nil, i.neonWiderMultiChannelLane == nil, i.neonWiderMultiChannelReplicate == nil, i.neonScalarShiftCompilerComposition == nil, i.neonScalarMaskSelection == nil, i.neonScalarIntegerComparison == nil, i.neonMultiChannelReplicate == nil else { throw Failure.unsupported("new82 foreign metadata exclusion") }
            guard i.neonPredicate == nil,i.neonMagnitudeClamp == nil,i.neonPairwise == nil,
                  i.neonLaneMemory == nil,i.neonBroadcastMemory == nil,i.neonBitCount == nil,
                  i.neonOrderConversion == nil,i.neonInterleavedMemory == nil,i.neonIndexedMemory == nil,
                  i.neonBufferMemory == nil,i.neonBufferSequence == nil,i.neonBitView == nil,
                  i.neonReduction == nil,i.neonPacking == nil,i.neonImmediate == nil,
                  i.neonMultiply == nil,i.neonShiftInsert == nil,i.neonExtract == nil,
                  i.neonPermutation == nil,i.neonModular == nil,i.neonComparison == nil,
                  i.neonTableLookup == nil,i.neonLogical == nil,i.scalarFP == nil else {
                throw Failure.unsupported("group widen narrow competing metadata")
            }
        }
        while position < list.count {
            let i=list[position];try exclusive(i)
            if let step=i.neonContiguousGroup {
                let f=step.frame
                guard step.ordinal == 0,f.frameSequence == sequence,f.firstByteSequence == byteSequence,
                      f.effectCount <= list.count-position else { throw Failure.unsupported("group widen narrow frame/byte order") }
                for ordinal in 0..<f.effectCount {
                    let e=list[position+ordinal];try exclusive(e)
                    guard e.neonMultiChannelLane == nil, e.neonWiderMultiChannelLane == nil, e.neonWiderMultiChannelReplicate == nil, e.neonScalarShiftCompilerComposition == nil, e.neonScalarIntegerComparison == nil, e.neonMultiChannelReplicate == nil else { throw Failure.unsupported("new82 foreign metadata exclusion") }
                    guard e.neonWideningPairwise == nil,e.neonShiftNarrow == nil,
                          e.source.address == i.source.address,e.neonContiguousGroup == .init(frame:f,ordinal:ordinal),
                          f.matches(e.operation,ordinal:ordinal),e.returnTarget == nil,
                          e.memoryAccess == (ordinal < f.groupCount ? MacIRMemoryAccess(byteWidth:f.activeBytes):nil),
                          e.id == .init(sourceAddress:i.source.address,effectOrdinal:ordinal) else {
                        throw Failure.unsupported("group widen narrow every interior shape/access/identity")
                    }
                }
                try base(f.oldBase,name:f.baseRegister)
                // All group vectors must be current before subsequent transforms.
                for value in f.vectors { _ = try vector(value,write:f.effect == .load) }
                if let d=f.baseDestination {
                    guard case let .register(name,version)=d,name == f.baseRegister,
                          version == bases[name,default:0]+1 else { throw Failure.unsupported("group widen narrow consecutive base write") }
                    bases[name]=version
                }
                entries.append(.init(family:f.effect == .load ? .loadGroup:.storeGroup,rowOrdinal:entries.count,startEffect:position,
                    identities:Array(list[position..<position+f.effectCount]).map(\.id),frameSequence:f.frameSequence,
                    firstByteSequence:f.firstByteSequence,activeBytes:f.activeBytes,memoryBlockCount:f.groupCount,
                    baseCommitOrdinal:f.baseDestination == nil ? nil:f.groupCount))
                sequence += 1;byteSequence += f.byteCount;position += f.effectCount;continue
            }
            guard i.memoryAccess == nil else { throw Failure.unsupported("group widen narrow untyped/Q memory") }
            let family:MacIRNEONGroupWidenNarrow.Family
            if let d=i.neonWideningPairwise {
                guard i.neonScalarVariableShift == nil, i.neonWiderChannelMemory == nil, i.neonMultiChannelLane == nil, i.neonWiderMultiChannelLane == nil, i.neonWiderMultiChannelReplicate == nil, i.neonScalarShiftCompilerComposition == nil, i.neonScalarMaskSelection == nil, i.neonScalarIntegerComparison == nil, i.neonMultiChannelReplicate == nil else { throw Failure.unsupported("new82 foreign metadata exclusion") }
                guard i.neonShiftNarrow == nil,i.returnTarget == nil,
                      case let .intrinsic(destination?,_,arguments)=i.operation,arguments.count == d.arity else { throw Failure.unsupported("group widen narrow widening shape") }
                _ = try vector(arguments[0],write:false)
                if d.accumulates {
                    let oldName=try vector(arguments[1],write:false)
                    guard case let .register(name,_)=destination,name == oldName else { throw Failure.unsupported("group widen narrow actual old accumulator") }
                }
                _ = try vector(destination,write:true);family = .widening
            } else if let d=i.neonShiftNarrow {
                guard i.returnTarget == nil,case let .intrinsic(destination?,_,arguments)=i.operation,arguments.count == d.arity else { throw Failure.unsupported("group widen narrow narrow shape") }
                _ = try vector(arguments[0],write:false)
                if d.destinationHighHalf {
                    let oldName=try vector(arguments[1],write:false)
                    guard case let .register(name,_)=destination,name == oldName else { throw Failure.unsupported("group widen narrow actual old SHRN2 destination") }
                }
                _ = try vector(destination,write:true);family = .narrow
            } else {
                switch i.operation {
                case .returnValue(nil) where position == list.count-1:
                    guard let target=i.returnTarget else { throw Failure.unsupported("group widen narrow missing return") }
                    try base(target,name:"x30");family = .terminal
                case .intrinsic(nil,"nop",let args) where args.isEmpty && i.returnTarget == nil:family = .nop
                default:throw Failure.unsupported("group widen narrow untyped effect")
                }
            }
            entries.append(.init(family:family,rowOrdinal:entries.count,startEffect:position,identities:[i.id]))
            position += 1
        }
        guard let certificate=MacIRNEONGroupWidenNarrow(entries:entries,effectCount:list.count) else {
            throw Failure.unsupported("group widen narrow complete bounded composition map")
        }
        return certificate
    }
}

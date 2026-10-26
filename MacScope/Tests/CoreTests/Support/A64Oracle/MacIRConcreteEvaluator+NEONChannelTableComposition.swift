import Foundation
#if canImport(MacScope)
@testable import MacScope
#endif

extension MacIRConcreteEvaluator {
    /// Full typed-list certification precedes payload dispatch. Source spelling
    /// and diagnostic intrinsic names never supply execution authority.
    func validateNEONChannelTableComposition(_ list:[MacIRInstruction]) throws -> MacIRNEONChannelTableComposition? {
        guard !list.contains(where: { $0.neonLaneCoefficientProduct != nil || $0.neonReplicatedIndexedProduct != nil }) else { throw Failure.unsupported("replicated product marker in standalone family") }
        guard list.contains(where: { $0.neonFourChannelMemory != nil }),
              list.contains(where: { $0.neonTableLookup != nil }) else { return nil }
        guard list.count <= 316,list.last?.operation == .returnValue(nil),Set(list.map(\.id)).count == list.count else {
            throw Failure.unsupported("channel table bound/identity/terminal")
        }
        var physicalFormals: Set<Int> = []
        for formal in function.parameters {
            guard case let .gpr(index, width) = formal.abiLocation, (0..<8).contains(index), width == 64,
                  formal.bindingID == .gpr(index), formal.register == "x\(index)", physicalFormals.insert(index).inserted else { throw Failure.unsupported("four channel unique exact64 physical formals") }
        }
        var position=0, sequence=0, byteSequence=0, globalByte=0, qSequence=0, rowCount=0, previousPC:UInt64?
        var entries:[MacIRNEONChannelTableComposition.Entry]=[]
        var channelValues:Set<MacIRValue>=[], transformedValues:Set<MacIRValue>=[], qValues:Set<MacIRValue>=[], usedQ:Set<MacIRValue>=[]
        var storedTransform=false
        var vectors:[String:Int]=[:], bases:[String:Int]=[:]
        func vector(_ value: MacIRValue, write: Bool) throws {
            guard case let .register(name, version)=value, let n=A64MachineState.vectorIndex(name), name == "v\(n)",
                  version == vectors[name,default:0]+(write ? 1:0) else { throw Failure.unsupported("four channel current physical128 vector") }
            if write { vectors[name]=version }
        }
        func base(_ value: MacIRValue, name: String) throws {
            guard let n=A64MachineState.gprIndex(name), n < 31, name == "x\(n)" else { throw Failure.unsupported("four channel ordinary base") }
            switch value {
            case let .register(actual,version):
                guard actual == name, version == bases[name,default:0],
                      version > 0 || !function.parameters.contains(where: { formal in
                          if case let .gpr(index, _) = formal.abiLocation, index == n { return true }
                          guard let binding = formal.bindingID else { return false }
                          return binding.kind == .gpr && binding.value == n
                      }) else { throw Failure.unsupported("four channel current base/formal") }
            case let .argument(binding):
                guard binding.kind == .gpr, (0..<8).contains(binding.value), name == "x\(binding.value)", bases[name,default:0] == 0,
                      function.parameters.filter({ $0.bindingID == binding }).count == 1,
                      function.parameters.first(where: { $0.bindingID == binding })?.abiLocation == .gpr(index:binding.value,carrierWidth:64) else { throw Failure.unsupported("four channel unbound/narrow base") }
            default: throw Failure.unsupported("four channel base shape")
            }
        }
        func exclusive(_ i:MacIRInstruction)throws {
            guard i.neonMultiChannelLane == nil, i.neonWiderChannelMemory == nil, i.neonScalarVariableShift == nil else { throw Failure.unsupported("current channel-family foreign metadata") }
            guard i.scalarFP == nil,
                  i.neonPermutation == nil,
                  i.neonLogical == nil,
                  i.neonExtract == nil,
                  i.neonModular == nil,
                  i.neonComparison == nil,
                  i.neonBitView == nil,
                  i.neonBufferSequence == nil,
                  i.neonShiftInsert == nil,
                  i.neonMultiply == nil,
                  i.neonImmediate == nil,
                  i.neonReduction == nil,
                  i.neonPacking == nil,
                  i.neonLaneMemory == nil,
                  i.neonWideningPairwise == nil,
                  i.neonPredicate == nil,
                  i.neonShiftNarrow == nil,
                  i.neonContiguousGroup == nil,
                  i.neonMagnitudeClamp == nil,
                  i.neonPairwise == nil,
                  i.neonBroadcastMemory == nil,
                  i.neonBitCount == nil,
                  i.neonOrderConversion == nil,
                  i.neonInterleavedMemory == nil,
                  i.neonIndexedMemory == nil,
                  i.neonWideningAddSubtract == nil,
                  i.neonSignedLongMultiply == nil,
                  i.neonWiderMultiChannelLane == nil, i.neonWiderMultiChannelReplicate == nil, i.neonScalarShiftCompilerComposition == nil, i.neonScalarMaskSelection == nil, i.neonScalarIntegerComparison == nil, i.neonMultiChannelReplicate == nil,
                  i.neonThreeChannelMemory == nil,
                  i.neonByteMatrixAccumulate == nil,
                  i.neonIndexedMixedByteDotProduct == nil,
                  i.neonMixedByteDotProduct == nil,
                  i.neonFullWidthShift == nil,
                  i.neonRoundedShift == nil,
                  i.neonSelectedSignedMultiply == nil,
                  i.neonSelectedWideningAccumulate == nil,
                  i.neonIndexedByteDotProduct == nil,
                  i.neonByteDotProduct == nil,
                  i.neonSelectedUnsignedMultiply == nil,
                  i.neonBytePolynomialMultiply == nil else { throw Failure.unsupported("channel table foreign metadata") }
            guard [i.neonFourChannelMemory != nil,i.neonTableLookup != nil,i.neonBufferMemory != nil].filter({ $0 }).count <= 1 else {
                throw Failure.unsupported("channel table competing metadata")
            }
        }
        // Check every interior, including foreign metadata on skipped commits.
        for i in list { try exclusive(i) }
        while position < list.count {
            let i=list[position],pc=i.source.address
            guard pc.isMultiple(of:4) else { throw Failure.unsupported("channel table PC alignment") }
            if let previousPC { guard previousPC <= UInt64.max-4,pc == previousPC+4 else { throw Failure.unsupported("channel table original PC order") } }
            previousPC=pc
            if let step=i.neonFourChannelMemory {
                let f=step.frame
                guard step.ordinal == 0,f.frameSequence == sequence,f.firstByteSequence == byteSequence,
                      f.effectCount <= list.count-position else { throw Failure.unsupported("channel table frame/byte order") }
                for ordinal in 0..<f.effectCount {
                    let e=list[position+ordinal]
                    guard e.source.address == pc,e.neonFourChannelMemory == .init(frame:f,ordinal:ordinal),
                          f.matches(e.operation,ordinal:ordinal),e.returnTarget == nil,e.memoryAccess == nil,
                          e.id == .init(sourceAddress:pc,effectOrdinal:ordinal) else { throw Failure.unsupported("channel table complete frame/commit") }
                    let family:MacIRNEONChannelTableComposition.Family = ordinal == 4 ? .baseCommit:(f.effect == .load ? .loadChannel:.storeChannel)
                    entries.append(.init(family:family,rowOrdinal:rowCount,effectSequence:position+ordinal,identity:e.id,
                        frameSequence:sequence,firstFrameByteSequence:byteSequence,firstGlobalByteSequence:globalByte,
                        channelOrdinal:ordinal < 4 ? ordinal:nil,activeBytes:f.activeBytes))
                }
                try base(f.oldBase,name:f.baseRegister)
                for value in f.vectors { try vector(value,write:f.effect == .load) }
                if f.effect == .load { channelValues.formUnion(f.vectors) }
                else if f.vectors.contains(where: { transformedValues.contains($0) }) { storedTransform=true }
                if let d=f.baseDestination {
                    guard case let .register(name,version)=d,name == f.baseRegister,name != "x30",
                          version == bases[name,default:0]+1 else { throw Failure.unsupported("channel table delayed base/original LR") }
                    bases[name]=version
                }
                sequence += 1;byteSequence += f.byteCount;globalByte += f.byteCount;position += f.effectCount
            } else {
                guard i.id == .init(sourceAddress:pc,effectOrdinal:0) else { throw Failure.unsupported("channel table singleton identity") }
                if let table=i.neonTableLookup {
                    guard i.memoryAccess == nil,i.returnTarget == nil,
                          case let .intrinsic(destination?,_,args)=i.operation,args.count == table.tableCount+2,
                          case let .register(destinationName,_)=destination,
                          case let .register(oldName,_)=args.last!,destinationName == oldName else {
                        throw Failure.unsupported("channel table complete lookup/OLD shape")
                    }
                    // All tables/index/OLD refer to current SSA BEFORE writing aliased Vd.
                    for value in args { try vector(value,write:false) }
                    guard case let .register(firstName,_)=args[0],let first=A64MachineState.vectorIndex(firstName) else {
                        throw Failure.unsupported("channel table first table")
                    }
                    for n in 0..<table.tableCount {
                        guard case let .register(name,_)=args[n],name == "v\((first+n)%32)" else {
                            throw Failure.unsupported("channel table consecutive full128 tables")
                        }
                    }
                    let payloadInputs=args.dropLast()
                    usedQ.formUnion(payloadInputs.filter { qValues.contains($0) })
                    let consumesChannel=payloadInputs.contains { channelValues.contains($0) }
                    try vector(destination,write:true)
                    if consumesChannel { channelValues.insert(destination);transformedValues.insert(destination) }
                    entries.append(.init(family:.table,rowOrdinal:rowCount,effectSequence:position,identity:i.id))
                } else if let memory=i.neonBufferMemory {
                    guard memory.effect == .load,memory.sequence == qSequence,i.memoryAccess == .init(byteWidth:16),
                          i.returnTarget == nil,case let .load(destination,address)=i.operation,address == memory.address else {
                        throw Failure.unsupported("channel table Q input shape/order")
                    }
                    let name:String
                    switch memory.base {
                    case let .register(n,_):name=n
                    case let .argument(b):name="x\(b.value)"
                    default:throw Failure.unsupported("channel table Q base shape")
                    }
                    try base(memory.base,name:name);try vector(destination,write:true);qValues.insert(destination)
                    entries.append(.init(family:.qLoad,rowOrdinal:rowCount,effectSequence:position,identity:i.id,
                        firstGlobalByteSequence:globalByte,activeBytes:16,qSequence:qSequence))
                    qSequence += 1;globalByte += 16
                } else {
                    guard i.memoryAccess == nil else { throw Failure.unsupported("channel table untyped memory") }
                    let family:MacIRNEONChannelTableComposition.Family
                    switch i.operation {
                    case .returnValue(nil) where position == list.count-1:
                        guard i.returnTarget == .register(name:"x30",version:0),bases["x30",default:0] == 0 else {
                            throw Failure.unsupported("channel table original X30")
                        };family = .terminal
                    case .intrinsic(nil,"nop",let a) where a.isEmpty && i.returnTarget == nil:family = .nop
                    default:throw Failure.unsupported("channel table foreign/untyped effect")
                    }
                    entries.append(.init(family:family,rowOrdinal:rowCount,effectSequence:position,identity:i.id))
                }
                position += 1
            }
            rowCount += 1
        }
        guard storedTransform,qValues.isSubset(of:usedQ),let certificate=MacIRNEONChannelTableComposition(entries:entries) else {
            throw Failure.unsupported("channel table missing loaded-channel/table/latest-ST4 outcome or unused Q input")
        }
        return certificate
    }
}

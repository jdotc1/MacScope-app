import Foundation
#if canImport(MacScope)
@testable import MacScope
#endif

extension MacIRConcreteEvaluator {
    /// Only successful exhaustive validation of THIS complete list permits the
    /// standalone59 bypass. Every frame interior is checked before any payload.
    /// The consumer below never infers semantics from source or diagnostic names.
    func validateNEONRGBLogicalBuffer(_ list:[MacIRInstruction]) throws -> MacIRNEONRGBLogicalBuffer? {
        guard !list.contains(where: { $0.neonLaneCoefficientProduct != nil || $0.neonReplicatedIndexedProduct != nil }) else { throw Failure.unsupported("replicated product marker in standalone family") }
        guard list.contains(where:{ $0.neonThreeChannelMemory != nil }),list.contains(where:{ $0.neonLogical != nil }) else { return nil }
        guard list.count <= 253,list.last?.operation == .returnValue(nil),Set(list.map(\.id)).count == list.count,
              !function.parameters.contains(where:{ switch $0.abiLocation { case .simd,.entryStack:return true;default:return false } }) else {
            throw Failure.unsupported("RGB bound/identity/formals/terminal")
        }
        var p=0,row=0,frame=0,byte=0,previous:UInt64?,vectors:[String:Int]=[:],bases:[String:Int]=[:]
        var entries:[MacIRNEONRGBLogicalBuffer.Entry]=[]
        func formals(_ index:Int)->[MacIRFunctionParameter] {
            function.parameters.filter { f in
                if case let .gpr(n,_) = f.abiLocation,n == index { return true }
                if f.bindingID?.kind == .gpr,f.bindingID?.value == index { return true }
                return f.register == "x\(index)" || f.register == "w\(index)"
            }
        }
        guard (0...30).allSatisfy({ formals($0).count <= 1 }) else { throw Failure.unsupported("RGB physical W/X formal uniqueness") }
        func vector(_ value:MacIRValue,write:Bool)throws->String {
            guard case let .register(name,version)=value,let n=A64MachineState.vectorIndex(name),name == "v\(n)",
                  version == vectors[name,default:0]+(write ? 1:0) else { throw Failure.unsupported("RGB current physical128 vector") }
            if write { vectors[name]=version };return name
        }
        func base(_ value:MacIRValue,name:String)throws {
            guard let n=A64MachineState.gprIndex(name),name == "x\(n)" else { throw Failure.unsupported("RGB ordinary base") }
            let matches=formals(n)
            if let f=matches.first {
                guard n < 8,f.abiLocation == .gpr(index:n,carrierWidth:64),f.bindingID == .gpr(n) else { throw Failure.unsupported("RGB exact64 physical formal") }
            }
            switch value {
            case let .register(actual,version):
                guard actual == name,version == bases[name,default:0],version > 0 || matches.isEmpty else { throw Failure.unsupported("RGB latest base/formal") }
            case let .argument(binding):
                guard binding.kind == .gpr,binding.value == n,matches.count == 1,bases[name,default:0] == 0 else { throw Failure.unsupported("RGB current argument base") }
            default:throw Failure.unsupported("RGB base shape")
            }
        }
        func exclusive(_ i:MacIRInstruction)throws {
            guard i.neonFullWidthShift == nil, i.neonScalarVariableShift == nil, i.neonWiderChannelMemory == nil, i.neonMultiChannelLane == nil, i.neonWiderMultiChannelLane == nil, i.neonWiderMultiChannelReplicate == nil, i.neonScalarShiftCompilerComposition == nil, i.neonScalarMaskSelection == nil, i.neonScalarIntegerComparison == nil, i.neonMultiChannelReplicate == nil, i.neonFourChannelMemory == nil, i.neonMixedByteDotProduct == nil, i.neonByteMatrixAccumulate == nil, i.neonIndexedMixedByteDotProduct == nil, i.neonSelectedWideningAccumulate == nil, i.neonSelectedSignedMultiply == nil, i.neonIndexedByteDotProduct == nil, i.neonContiguousGroup == nil,i.neonSignedLongMultiply == nil,i.neonWideningAddSubtract == nil,
                  i.neonShiftNarrow == nil,i.neonPredicate == nil,i.neonWideningPairwise == nil,i.neonMagnitudeClamp == nil,
                  i.neonPairwise == nil,i.neonLaneMemory == nil,i.neonBroadcastMemory == nil,i.neonBitCount == nil,
                  i.neonOrderConversion == nil,i.neonInterleavedMemory == nil,i.neonIndexedMemory == nil,i.neonBufferMemory == nil,
                  i.neonBufferSequence == nil,i.neonBitView == nil,i.neonReduction == nil,i.neonPacking == nil,
                  i.neonImmediate == nil,i.neonMultiply == nil,i.neonShiftInsert == nil,i.neonExtract == nil,
                  i.neonPermutation == nil,i.neonModular == nil,i.neonComparison == nil,i.neonTableLookup == nil,
                  i.neonRoundedShift == nil,i.neonByteDotProduct == nil,i.neonSelectedUnsignedMultiply == nil,
                  i.neonBytePolynomialMultiply == nil,i.scalarFP == nil else { throw Failure.unsupported("RGB foreign metadata") }
        }
        // Complete-list pass, not just starts of frames later consumed as units.
        for i in list { try exclusive(i) }
        while p < list.count {
            let i=list[p],pc=i.source.address
            guard pc.isMultiple(of:4) else { throw Failure.unsupported("RGB original PC alignment") }
            if let previous { guard previous <= UInt64.max-4,pc == previous+4 else { throw Failure.unsupported("RGB original PC contiguous") } };previous=pc
            if let step=i.neonThreeChannelMemory {
                let f=step.frame
                guard step.ordinal == 0,f.frameSequence == frame,f.firstByteSequence == byte,f.effectCount <= list.count-p else { throw Failure.unsupported("RGB frame/access sequence") }
                for ordinal in 0..<f.effectCount {
                    let e=list[p+ordinal]
                    guard e.source.address == pc,e.neonThreeChannelMemory == .init(frame:f,ordinal:ordinal),e.neonLogical == nil,
                          f.matches(e.operation,ordinal:ordinal),e.returnTarget == nil,e.memoryAccess == nil,
                          e.id == .init(sourceAddress:pc,effectOrdinal:ordinal) else { throw Failure.unsupported("RGB complete frame/commit shape") }
                    let family:MacIRNEONRGBLogicalBuffer.Family = ordinal == 3 ? .baseCommit:(f.effect == .load ? .loadChannel:.storeChannel)
                    entries.append(.init(family:family,rowOrdinal:row,effectSequence:p+ordinal,identity:e.id,frameSequence:frame,
                        firstByteSequence:byte,channelOrdinal:ordinal < 3 ? ordinal:nil,activeBytes:f.activeBytes))
                }
                try base(f.oldBase,name:f.baseRegister)
                // All stores use latest channel values; loads define full physical128.
                for value in f.vectors { _ = try vector(value,write:f.effect == .load) }
                if let d=f.baseDestination {
                    guard case let .register(name,version)=d,name == f.baseRegister,version == bases[name,default:0]+1 else { throw Failure.unsupported("RGB delayed next base") }
                    bases[name]=version
                }
                frame += 1;byte += f.byteCount;p += f.effectCount
            } else {
                guard i.memoryAccess == nil,i.id == .init(sourceAddress:pc,effectOrdinal:0) else { throw Failure.unsupported("RGB untyped access/effect identity") }
                let family:MacIRNEONRGBLogicalBuffer.Family
                if let d=i.neonLogical {
                    guard i.returnTarget == nil,case let .intrinsic(destination?,_,args)=i.operation,args.count == (d.readsDestination ? 3:2) else { throw Failure.unsupported("RGB logical shape") }
                    for a in args { _ = try vector(a,write:false) }
                    if d.readsDestination {
                        guard case let .register(name,_)=destination,case let .register(oldName,_)=args[2],name == oldName else { throw Failure.unsupported("RGB actual OLD destination") }
                    }
                    _ = try vector(destination,write:true);family = .logical
                } else {
                    switch i.operation {
                    case .returnValue(nil) where p == list.count-1:
                        guard let target=i.returnTarget else { throw Failure.unsupported("RGB return target") };try base(target,name:"x30");family = .terminal
                    case .intrinsic(nil,"nop",let args) where args.isEmpty && i.returnTarget == nil:family = .nop
                    default:throw Failure.unsupported("RGB foreign/untyped operation")
                    }
                }
                entries.append(.init(family:family,rowOrdinal:row,effectSequence:p,identity:i.id));p += 1
            }
            row += 1
        }
        guard let certificate=MacIRNEONRGBLogicalBuffer(entries:entries) else { throw Failure.unsupported("RGB complete original/frame/effect/byte map") }
        return certificate
    }
}

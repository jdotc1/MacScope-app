import Foundation
@testable import MacScope

extension MacIRConcreteEvaluator {
    /// Whole-list structural validation before any payload effect, including
    /// descriptors attached to an interior effect another dispatcher would skip.
    func validateNEONIndexedMemory(_ list:[MacIRInstruction]) throws {
        guard !list.contains(where: { $0.neonLaneCoefficientProduct != nil || $0.neonReplicatedIndexedProduct != nil }) else { throw Failure.unsupported("replicated product marker in standalone family") }
        guard list.contains(where:{$0.neonIndexedMemory != nil}) else{return}
        var ordinal=0
        for i in list {
            guard i.neonScalarVariableShift == nil, i.neonWiderChannelMemory == nil, i.neonMultiChannelLane == nil, i.neonWiderMultiChannelLane == nil, i.neonWiderMultiChannelReplicate == nil, i.neonScalarShiftCompilerComposition == nil, i.neonScalarMaskSelection == nil, i.neonScalarIntegerComparison == nil, i.neonMultiChannelReplicate == nil else { throw Failure.unsupported("new82 foreign metadata exclusion") }
            guard i.neonBufferSequence == nil,i.neonBitView == nil,i.neonReduction == nil,i.neonPacking == nil,
                  i.neonImmediate == nil,i.neonMultiply == nil,i.neonShiftInsert == nil,i.neonExtract == nil,
                  i.neonPermutation == nil,i.neonModular == nil,i.neonComparison == nil,i.neonTableLookup == nil,
                  i.scalarFP == nil else{throw Failure.unsupported("NEON indexed family union")}
            guard [i.neonIndexedMemory != nil,i.neonBufferMemory != nil,i.neonLogical != nil].filter({$0}).count <= 1 else{throw Failure.unsupported("NEON indexed competing metadata")}
            if let d=i.neonIndexedMemory {
                guard d.sequence == ordinal,i.memoryAccess == .init(byteWidth:16),i.returnTarget == nil else{throw Failure.unsupported("NEON indexed ordinal/access")}
                try validateIndexedShape(d,i.operation);ordinal+=1
            } else if let d=i.neonBufferMemory {
                guard d.sequence == ordinal,i.memoryAccess == .init(byteWidth:16),i.returnTarget == nil else{throw Failure.unsupported("NEON indexed retained ordinal/access")}
                let v:MacIRValue
                switch(d.effect,i.operation){case let(.load,.load(destination,address)) where address == d.address:v=destination
                case let(.store,.store(source,address)) where address == d.address:v=source
                default:throw Failure.unsupported("NEON indexed retained shape")}
                try validateIndexedCarrier(v,load:d.effect == .load);ordinal+=1
            } else {
                guard i.memoryAccess == nil else{throw Failure.unsupported("NEON indexed untyped access")}
                if i.neonLogical != nil {guard i.returnTarget == nil else{throw Failure.unsupported("NEON indexed logical return")};continue}
                switch i.operation {
                case .returnValue(nil):break
                case .intrinsic(nil,_,let args) where args.isEmpty:break
                default:throw Failure.unsupported("NEON indexed untyped effect")
                }
            }
        }
    }
    private func validateIndexedCarrier(_ v:MacIRValue,load:Bool)throws {
        guard case let .register(name,version)=v,let n=A64MachineState.vectorIndex(name),name == "v\(n)",version >= (load ? 1 : 0) else{throw Failure.unsupported("NEON indexed vector carrier")}
    }
    private func validateIndexedShape(_ d:MacIRNEONIndexedMemory,_ op:MacIROperation)throws {
        switch(d.effect,op){
        case let(.load,.load(destination,address)) where address == d.address:try validateIndexedCarrier(destination,load:true)
        case let(.store,.store(source,address)) where address == d.address:try validateIndexedCarrier(source,load:false)
        default:throw Failure.unsupported("NEON indexed operation/address")
        }
    }
    mutating func executeNEONIndexedMemory(_ d:MacIRNEONIndexedMemory,operation:MacIROperation,memoryAccess:MacIRMemoryAccess?)throws {
        try validateIndexedShape(d,operation)
        // Preserve current evaluator argument/projection semantics. W masks before
        // extension; SXTX and LSL retain all64 bits. No numeric X/Q alias relation.
        let base=try evaluate(d.base),index=try evaluate(d.index)
        guard base.width == 64,base.kind != .float,index.width == d.indexExtension.width,index.kind != .float else{throw Failure.unsupported("NEON indexed GPR width")}
        let bits:UInt64
        switch d.indexExtension {
        case .uxtw:bits=UInt64(UInt32(truncatingIfNeeded:index.bits))
        case .sxtw:bits=UInt64(bitPattern:Int64(Int32(bitPattern:UInt32(truncatingIfNeeded:index.bits))))
        case .lsl,.sxtx:bits=index.bits
        }
        let address=base.bits &+ (bits << d.shift)
        guard address <= UInt64.max-15 else{throw Failure.unsupported("NEON indexed address span")}
        // Reuse authoritative31 byte collection, full128 source read/write and
        // memory payload logic, with already-resolved address and zero offset.
        //31 immediate arithmetic semantics are unchanged.
        let resolved=MacIRNEONBufferMemory(effect:d.effect,base:.immediate(Int64(bitPattern:address)),byteOffset:0,sequence:d.sequence)!
        let op:MacIROperation
        switch operation {
        case let .load(destination,_):op = .load(destination:destination,address:resolved.address)
        case let .store(source,_):op = .store(source:source,address:resolved.address)
        default:throw Failure.unsupported("NEON indexed operation")
        }
        try executeNEONBufferMemory(resolved,operation:op,memoryAccess:memoryAccess)
    }
}

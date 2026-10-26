import Foundation
#if canImport(MacScope)
@testable import MacScope
#endif

extension MacIRConcreteEvaluator {
    /// Only a complete, validated explicit47+48 composition replaces their
    /// independent validators. No middle slice is validated with reset counters.
    /// This is structural preflight; dynamic spans/value widths remain per-effect
    /// in unchanged31/47/48 consumers. Earlier successful effects are NOT rolled back.
    func validateNEONLaneBroadcastBuffer(_ list: [MacIRInstruction]) throws -> MacIRNEONLaneBroadcastBuffer? {
        guard !list.contains(where: { $0.neonLaneCoefficientProduct != nil || $0.neonReplicatedIndexedProduct != nil }) else { throw Failure.unsupported("replicated product marker in standalone family") }
        guard list.contains(where: { $0.neonBroadcastMemory != nil }),
              list.contains(where: { $0.neonLaneMemory != nil }) else { return nil }
        guard (3...127).contains(list.count), let last = list.last, last.operation == .returnValue(nil),
              Set(list.map(\.id)).count == list.count,
              !function.parameters.contains(where: {
                  switch $0.abiLocation { case .simd, .entryStack: return true; default: return false }
              }) else { throw Failure.unsupported("lane/broadcast whole-list bound/identity/formal") }
        var vectors: [String:Int] = [:], bases: [String:Int] = [:]
        var position = 0, rows = 0, scalarQ = 0, laneFrame = 0, laneByte = 0, q = 0, payloadByte = 0
        var previousPC: UInt64?, entries: [MacIRNEONLaneBroadcastBuffer.Entry] = []
        func vector(_ value: MacIRValue, write: Bool) throws {
            guard case let .register(name,version) = value, let n = A64MachineState.vectorIndex(name), name == "v\(n)",
                  version == vectors[name,default:0] + (write ? 1:0) else { throw Failure.unsupported("lane/broadcast current physical128 vector") }
            if write { vectors[name] = version }
        }
        func base(_ value: MacIRValue, required: String? = nil) throws {
            let name: String, version: Int
            switch value {
            case let .register(n,v):
                name = n; version = v
                // Never replace a live bound formal with an invented entry register.
                guard v != 0 || !function.parameters.contains(where: { $0.register == n && $0.bindingID != nil }) else {
                    throw Failure.unsupported("lane/broadcast bypassed entry formal")
                }
            case let .argument(binding):
                guard binding.kind == .gpr, (0..<8).contains(binding.value),
                      function.parameters.filter({ $0.bindingID == binding }).count == 1,
                      let formal = function.parameters.first(where: { $0.bindingID == binding }),
                      formal.abiLocation == .gpr(index:binding.value,carrierWidth:64) else { throw Failure.unsupported("lane/broadcast unbound/narrow formal") }
                name = "x\(binding.value)"; version = 0
            default: throw Failure.unsupported("lane/broadcast base tombstone/shape")
            }
            guard let n = A64MachineState.gprIndex(name), n < 31, name == "x\(n)",
                  required == nil || name == required, version == bases[name,default:0] else {
                throw Failure.unsupported("lane/broadcast current base/return")
            }
        }
        func baseWrite(_ value: MacIRValue?, name: String) throws {
            guard let value else { return }
            guard value == .register(name:name,version:bases[name,default:0]+1) else { throw Failure.unsupported("lane/broadcast delayed base version") }
            bases[name,default:0] += 1
        }
        func exclusive(_ i: MacIRInstruction) throws {
            guard i.neonScalarVariableShift == nil, i.neonWiderChannelMemory == nil, i.neonMultiChannelLane == nil, i.neonWiderMultiChannelLane == nil, i.neonWiderMultiChannelReplicate == nil, i.neonScalarShiftCompilerComposition == nil, i.neonScalarMaskSelection == nil, i.neonScalarIntegerComparison == nil, i.neonMultiChannelReplicate == nil else { throw Failure.unsupported("new82 foreign metadata exclusion") }
            guard i.neonMagnitudeClamp == nil, i.neonPairwise == nil,
                  i.neonBitCount == nil, i.neonOrderConversion == nil, i.neonInterleavedMemory == nil,
                  i.neonIndexedMemory == nil, i.neonBufferSequence == nil, i.neonBitView == nil,
                  i.neonReduction == nil, i.neonPacking == nil, i.neonImmediate == nil,
                  i.neonMultiply == nil, i.neonShiftInsert == nil, i.neonExtract == nil,
                  i.neonPermutation == nil, i.neonModular == nil, i.neonComparison == nil,
                  i.neonTableLookup == nil, i.scalarFP == nil,
                  [i.neonBroadcastMemory != nil,i.neonLaneMemory != nil,i.neonBufferMemory != nil,i.neonLogical != nil].filter({ $0 }).count <= 1 else {
                throw Failure.unsupported("lane/broadcast excluded/competing family")
            }
        }
        // Inspect ALL interiors before any dispatcher can consume a frame.
        for i in list { try exclusive(i) }
        func entry(_ family: MacIRNEONLaneBroadcastBuffer.Family, _ count: Int, _ bytes: Int) {
            entries.append(.init(family:family,startEffect:position,identities:Array(list[position..<position+count]).map(\.id),
                transferOrdinal:entries.count,firstPayloadByte:payloadByte,byteCount:bytes,
                scalarQSequence:family == .lane ? nil:scalarQ,
                laneFrameSequence:family == .lane ? laneFrame:nil,
                laneFirstByteSequence:family == .lane ? laneByte:nil,qOrdinal:family == .q ? q:nil))
            payloadByte += bytes
        }
        while position < list.count {
            let i = list[position]
            guard i.source.address.isMultiple(of:4) else { throw Failure.unsupported("lane/broadcast realPC alignment") }
            if let previousPC {
                guard previousPC <= UInt64.max-4, i.source.address == previousPC+4 else { throw Failure.unsupported("lane/broadcast realPC row order") }
            }
            previousPC = i.source.address; rows += 1
            guard rows <= 64 else { throw Failure.unsupported("lane/broadcast source-row bound") }
            if let step = i.neonBroadcastMemory {
                let f = step.frame
                guard step.ordinal == 0, f.sequence == scalarQ, f.effectCount < list.count-position else { throw Failure.unsupported("lane/broadcast47 framing/order") }
                for ordinal in 0..<f.effectCount {
                    let e = list[position+ordinal]
                    guard e.neonBroadcastMemory == .init(frame:f,ordinal:ordinal), e.source.address == i.source.address,
                          f.matches(e.operation,ordinal:ordinal), e.returnTarget == nil,
                          e.memoryAccess == (ordinal == 0 ? MacIRMemoryAccess(byteWidth:f.byteCount):nil) else {
                        throw Failure.unsupported("lane/broadcast47 interior/access")
                    }
                }
                try base(f.oldBase,required:f.baseRegister); try vector(f.destination,write:true)
                try baseWrite(f.baseDestination,name:f.baseRegister)
                entry(.broadcast,f.effectCount,f.byteCount); scalarQ += 1; position += f.effectCount; continue
            }
            if let step = i.neonLaneMemory {
                let f = step.frame
                guard step.ordinal == 0, f.frameSequence == laneFrame, f.firstByteSequence == laneByte,
                      f.effectCount < list.count-position else { throw Failure.unsupported("lane/broadcast48 frame/byte order") }
                for ordinal in 0..<f.effectCount {
                    let e = list[position+ordinal]
                    guard e.neonLaneMemory == .init(frame:f,ordinal:ordinal), e.source.address == i.source.address,
                          f.matches(e.operation,ordinal:ordinal), e.returnTarget == nil,
                          e.memoryAccess == (ordinal == 0 ? MacIRMemoryAccess(byteWidth:f.byteCount):nil) else {
                        throw Failure.unsupported("lane/broadcast48 interior/access")
                    }
                }
                try base(f.oldBase,required:f.baseRegister); try vector(f.oldVector,write:false)
                if let destination = f.destination { try vector(destination,write:true) }
                try baseWrite(f.baseDestination,name:f.baseRegister)
                entry(.lane,f.effectCount,f.byteCount); laneFrame += 1; laneByte += f.byteCount; position += f.effectCount; continue
            }
            if let memory = i.neonBufferMemory {
                guard memory.sequence == scalarQ, i.memoryAccess == .init(byteWidth:16), i.returnTarget == nil else { throw Failure.unsupported("lane/broadcast31 scalarQ order/access") }
                try base(memory.base)
                switch (memory.effect,i.operation) {
                case let (.load,.load(destination,address)) where address == memory.address: try vector(destination,write:true)
                case let (.store,.store(source,address)) where address == memory.address: try vector(source,write:false)
                default: throw Failure.unsupported("lane/broadcast31 shape")
                }
                entry(.q,1,16); scalarQ += 1; q += 1
            } else if let logical = i.neonLogical {
                guard logical.kind == .eor, logical.width == .bytes16, i.memoryAccess == nil, i.returnTarget == nil,
                      case let .intrinsic(destination?,_,arguments) = i.operation, arguments.count == 2 else { throw Failure.unsupported("lane/broadcast exact EOR shape") }
                for source in arguments { try vector(source,write:false) }
                try vector(destination,write:true)
            } else {
                guard i.memoryAccess == nil else { throw Failure.unsupported("lane/broadcast untyped memory") }
                switch i.operation {
                case .returnValue(nil) where position == list.count-1:
                    guard let target = i.returnTarget else { throw Failure.unsupported("lane/broadcast missing return target") }
                    try base(target,required:"x30")
                case .intrinsic(nil,"nop",let arguments) where arguments.isEmpty && i.returnTarget == nil: break
                default: throw Failure.unsupported("lane/broadcast untyped effect")
                }
            }
            position += 1
        }
        guard let certificate = MacIRNEONLaneBroadcastBuffer(entries:entries,effectCount:list.count,rowCount:rows) else {
            throw Failure.unsupported("lane/broadcast framing certificate")
        }
        return certificate
    }
}

import Foundation
#if canImport(MacScope)
@testable import MacScope
#endif

extension MacIRConcreteEvaluator {
    /// Full-list shape/SSA preflight includes every frame interior, before any
    /// payload dispatch. Dynamic memory span checks remain per successful frame;
    /// no rollback, fault atomicity or transaction semantics are asserted.
    func validateNEONThreeChannelMemory(_ list: [MacIRInstruction]) throws {
        guard !list.contains(where: { $0.neonLaneCoefficientProduct != nil || $0.neonReplicatedIndexedProduct != nil }) else { throw Failure.unsupported("replicated product marker in standalone family") }
        guard list.contains(where: { $0.neonThreeChannelMemory != nil }) else { return }
        guard list.count <= 253, list.last?.operation == .returnValue(nil),
              Set(list.map(\.id)).count == list.count,
              !function.parameters.contains(where: {
                  switch $0.abiLocation { case .simd,.entryStack: return true; default: return false }
              }) else { throw Failure.unsupported("three channel bound/identity/formals/terminal") }
        var position=0, sequence=0, byteSequence=0, rowCount=0, loads=0, stores=0, previousPC:UInt64?
        var vectors:[String:Int]=[:], bases:[String:Int]=[:]
        func vector(_ value: MacIRValue, write: Bool) throws {
            guard case let .register(name, version)=value, let n=A64MachineState.vectorIndex(name), name == "v\(n)",
                  version == vectors[name,default:0]+(write ? 1:0) else { throw Failure.unsupported("three channel current physical128 vector") }
            if write { vectors[name]=version }
        }
        func base(_ value: MacIRValue, name: String) throws {
            guard let n=A64MachineState.gprIndex(name), n < 31, name == "x\(n)" else { throw Failure.unsupported("three channel ordinary base") }
            switch value {
            case let .register(actual,version):
                guard actual == name, version == bases[name,default:0],
                      version > 0 || !function.parameters.contains(where: { $0.register == name && $0.bindingID != nil }) else { throw Failure.unsupported("three channel current base/formal") }
            case let .argument(binding):
                guard binding.kind == .gpr, (0..<8).contains(binding.value), name == "x\(binding.value)", bases[name,default:0] == 0,
                      function.parameters.filter({ $0.bindingID == binding }).count == 1,
                      function.parameters.first(where: { $0.bindingID == binding })?.abiLocation == .gpr(index:binding.value,carrierWidth:64) else { throw Failure.unsupported("three channel unbound/narrow base") }
            default: throw Failure.unsupported("three channel base shape")
            }
        }
        func exclusive(_ i: MacIRInstruction) throws {
            guard i.neonFullWidthShift == nil, i.neonScalarVariableShift == nil, i.neonWiderChannelMemory == nil, i.neonMultiChannelLane == nil, i.neonWiderMultiChannelLane == nil, i.neonWiderMultiChannelReplicate == nil, i.neonScalarShiftCompilerComposition == nil, i.neonScalarMaskSelection == nil, i.neonScalarIntegerComparison == nil, i.neonMultiChannelReplicate == nil, i.neonFourChannelMemory == nil, i.neonMixedByteDotProduct == nil, i.neonByteMatrixAccumulate == nil, i.neonIndexedMixedByteDotProduct == nil, i.neonSelectedWideningAccumulate == nil, i.neonIndexedByteDotProduct == nil, i.neonContiguousGroup == nil, i.neonSignedLongMultiply == nil, i.neonWideningAddSubtract == nil,
                  i.neonShiftNarrow == nil, i.neonPredicate == nil, i.neonWideningPairwise == nil, i.neonMagnitudeClamp == nil,
                  i.neonPairwise == nil, i.neonLaneMemory == nil, i.neonBroadcastMemory == nil, i.neonBitCount == nil,
                  i.neonOrderConversion == nil, i.neonInterleavedMemory == nil, i.neonIndexedMemory == nil, i.neonBufferMemory == nil,
                  i.neonBufferSequence == nil, i.neonBitView == nil, i.neonReduction == nil, i.neonPacking == nil,
                  i.neonImmediate == nil, i.neonMultiply == nil, i.neonShiftInsert == nil, i.neonExtract == nil,
                  i.neonPermutation == nil, i.neonModular == nil, i.neonComparison == nil, i.neonTableLookup == nil,
                  i.neonLogical == nil, i.scalarFP == nil else { throw Failure.unsupported("three channel competing metadata") }
        }
        while position < list.count {
            let i=list[position];try exclusive(i)
            guard i.source.address.isMultiple(of:4) else { throw Failure.unsupported("three channel PC alignment") }
            if let pc=previousPC { guard pc <= UInt64.max-4, i.source.address == pc+4 else { throw Failure.unsupported("three channel real PC order") } }
            previousPC=i.source.address;rowCount += 1
            if let step=i.neonThreeChannelMemory {
                let f=step.frame
                guard step.ordinal == 0, f.frameSequence == sequence, f.firstByteSequence == byteSequence,
                      f.effectCount <= list.count-position else { throw Failure.unsupported("three channel frame/byte order") }
                for ordinal in 0..<f.effectCount {
                    let e=list[position+ordinal];try exclusive(e)
                    guard e.source.address == i.source.address, e.neonThreeChannelMemory == .init(frame:f,ordinal:ordinal),
                          f.matches(e.operation,ordinal:ordinal), e.returnTarget == nil,
                          e.memoryAccess == nil,
                          e.id == .init(sourceAddress:i.source.address,effectOrdinal:ordinal) else {
                        throw Failure.unsupported("three channel commit/access shape")
                    }
                }
                try base(f.oldBase,name:f.baseRegister)
                for value in f.vectors { try vector(value,write:f.effect == .load) }
                if let d=f.baseDestination, case let .register(name,version)=d {
                    guard version == bases[name,default:0]+1 else { throw Failure.unsupported("three channel next base") };bases[name]=version
                }
                if f.effect == .load { loads += 1 } else { stores += 1 }
                sequence += 1;byteSequence += f.byteCount;position += f.effectCount;continue
            }
            guard i.memoryAccess == nil else { throw Failure.unsupported("three channel untyped memory") }
            switch i.operation {
            case .returnValue(nil) where position == list.count-1:
                guard let target=i.returnTarget else { throw Failure.unsupported("three channel missing return") };try base(target,name:"x30")
            case .intrinsic(nil,"nop",let a) where a.isEmpty && i.returnTarget == nil: break
            default: throw Failure.unsupported("three channel untyped effect")
            }
            position += 1
        }
        guard (3...64).contains(rowCount), loads > 0, stores > 0 else { throw Failure.unsupported("three channel incomplete copy/budget") }
    }
    mutating func executeNEONThreeChannelMemory(_ f: MacIRNEONThreeChannelMemory) throws {
        let old=try evaluate(f.oldBase)
        guard old.width == 64, old.kind != .float, old.bits <= UInt64.max-UInt64(f.byteCount-1) else {
            throw Failure.unsupported("three channel complete span/base")
        }
        let updated=old.bits &+ UInt64(f.fixedPostDelta)
        // Complete 24/48-byte span was checked. Snapshot ALL store sources or ALL
        // load bytes into independent payloads before any vector/memory/base write.
        var payloads=[[UInt8]](repeating:[UInt8](repeating:0,count:16),count:f.groupCount)
        if f.effect == .store {
            let sources=try f.vectors.map { try readNEONRegister($0) }
            guard sources.allSatisfy({ $0.width == 128 }) else { throw Failure.unsupported("three channel physical128 store snapshots") }
            for n in 0..<f.groupCount {
                for lane in 0..<f.activeBytes {
                    let s=sources[n];payloads[n][lane]=UInt8(truncatingIfNeeded:(lane < 8 ? s.bits:s.high) >> ((lane%8)*8))
                }
            }
        } else {
            for b in f.orderedBytes { payloads[b.vector][b.lane]=state.byte(at:old.bits+UInt64(b.offset)) }
        }
        if f.effect == .load {
            for n in 0..<f.groupCount {
                func half(_ start:Int)->UInt64 { (0..<8).reduce(0) { $0 | UInt64(payloads[n][start+$1]) << ($1*8) } }
                // A Q0 load defines full128 with high64 zero for EACH register.
                try writeNEONRegister(f.vectors[n],.init(bits:half(0),width:128,kind:.unsigned,high:half(8)))
            }
        } else {
            for b in f.orderedBytes { state.setByte(payloads[b.vector][b.lane],at:old.bits+UInt64(b.offset)) }
        }
        if let destination=f.baseDestination { try write(destination,.int(updated,width:64,signed:false)) }
    }
}

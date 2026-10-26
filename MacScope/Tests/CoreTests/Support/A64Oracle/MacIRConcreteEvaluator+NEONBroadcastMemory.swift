import Foundation
#if canImport(MacScope)
@testable import MacScope
#endif

extension MacIRConcreteEvaluator {
    /// Full-list structural preflight, including delayed base commit interiors.
    /// Global order counts one scalar broadcast or one retained Q transfer.
    /// Dynamic spans are checked per transfer; earlier transfers are not rolled back.
    func validateNEONBroadcastMemory(_ list: [MacIRInstruction]) throws {
        guard !list.contains(where: { $0.neonLaneCoefficientProduct != nil || $0.neonReplicatedIndexedProduct != nil }) else { throw Failure.unsupported("replicated product marker in standalone family") }
        guard list.contains(where: { $0.neonBroadcastMemory != nil }) else { return }
        guard list.count <= 129, let last = list.last, case .returnValue(nil) = last.operation else { throw Failure.unsupported("broadcast budget") }
        var position = 0, sequence = 0, versions: [String: Int] = [:], baseVersions: [String: Int] = [:]
        func vector(_ value: MacIRValue, write: Bool) throws {
            guard case let .register(name, version) = value, let index = A64MachineState.vectorIndex(name),
                  name == "v\(index)", version == versions[name, default: 0] + (write ? 1 : 0) else {
                throw Failure.unsupported("broadcast canonical vector snapshot")
            }
            if write { versions[name] = version }
        }
        func baseRead(_ value: MacIRValue, required: String? = nil) throws {
            let name: String, version: Int
            switch value {
            case let .register(n, v): name = n; version = v
            case let .argument(binding) where binding.kind == .gpr: name = "x\(binding.value)"; version = 0
            default: throw Failure.unsupported("broadcast canonical base shape")
            }
            guard let index = A64MachineState.gprIndex(name), name == "x\(index)",
                  required == nil || name == required, version == baseVersions[name, default: 0] else {
                throw Failure.unsupported("broadcast current base/return snapshot")
            }
        }
        func exclusive(_ i: MacIRInstruction) throws {
            guard i.neonScalarVariableShift == nil, i.neonWiderChannelMemory == nil, i.neonMultiChannelLane == nil, i.neonWiderMultiChannelLane == nil, i.neonWiderMultiChannelReplicate == nil, i.neonScalarShiftCompilerComposition == nil, i.neonScalarMaskSelection == nil, i.neonScalarIntegerComparison == nil, i.neonMultiChannelReplicate == nil else { throw Failure.unsupported("new82 foreign metadata exclusion") }
            guard i.neonBitCount == nil, i.neonOrderConversion == nil, i.neonInterleavedMemory == nil,
                  i.neonIndexedMemory == nil, i.neonBufferSequence == nil, i.neonBitView == nil,
                  i.neonReduction == nil, i.neonPacking == nil, i.neonImmediate == nil,
                  i.neonMultiply == nil, i.neonShiftInsert == nil, i.neonExtract == nil,
                  i.neonPermutation == nil, i.neonModular == nil, i.neonComparison == nil,
                  i.neonTableLookup == nil, i.scalarFP == nil else { throw Failure.unsupported("broadcast family union") }
        }
        while position < list.count {
            let i = list[position]; try exclusive(i)
            if let step = i.neonBroadcastMemory {
                let f = step.frame
                guard step.ordinal == 0, f.sequence == sequence, f.effectCount <= list.count-position else { throw Failure.unsupported("broadcast framing/order") }
                for ordinal in 0..<f.effectCount {
                    let e = list[position+ordinal]; try exclusive(e)
                    guard e.neonBroadcastMemory == .init(frame: f, ordinal: ordinal),
                          e.source.address == i.source.address, f.matches(e.operation, ordinal: ordinal),
                          e.memoryAccess == (ordinal == 0 ? MacIRMemoryAccess(byteWidth: f.byteCount) : nil),
                          e.neonBufferMemory == nil, e.neonLogical == nil, e.returnTarget == nil else { throw Failure.unsupported("broadcast commit/access shape") }
                }
                try baseRead(f.oldBase, required: f.baseRegister)
                if f.baseDestination != nil { baseVersions[f.baseRegister, default: 0] += 1 }
                try vector(f.destination, write: true)
                sequence += 1; position += f.effectCount; continue
            }
            if let memory = i.neonBufferMemory {
                guard i.neonScalarVariableShift == nil, i.neonWiderChannelMemory == nil, i.neonMultiChannelLane == nil, i.neonWiderMultiChannelLane == nil, i.neonWiderMultiChannelReplicate == nil, i.neonScalarShiftCompilerComposition == nil, i.neonScalarMaskSelection == nil, i.neonScalarIntegerComparison == nil, i.neonMultiChannelReplicate == nil else { throw Failure.unsupported("new82 foreign metadata exclusion") }
                guard i.neonLogical == nil, memory.sequence == sequence, i.memoryAccess == .init(byteWidth: 16), i.returnTarget == nil else { throw Failure.unsupported("broadcast Q ordinal/access") }
                try baseRead(memory.base)
                switch (memory.effect, i.operation) {
                case let (.load, .load(destination, address)) where address == memory.address: try vector(destination, write: true)
                case let (.store, .store(source, address)) where address == memory.address: try vector(source, write: false)
                default: throw Failure.unsupported("broadcast Q shape")
                }
                sequence += 1
            } else if let logical = i.neonLogical {
                guard logical.kind == .eor, logical.width == .bytes16, i.memoryAccess == nil, i.returnTarget == nil,
                      case let .intrinsic(destination?, _, arguments) = i.operation, arguments.count == 2 else { throw Failure.unsupported("broadcast logical shape") }
                for source in arguments { try vector(source, write: false) }
                try vector(destination, write: true)
            } else {
                guard i.memoryAccess == nil else { throw Failure.unsupported("broadcast untyped memory") }
                switch i.operation {
                case .returnValue(nil) where position == list.count-1:
                    guard let target = i.returnTarget else { throw Failure.unsupported("broadcast missing return target") }
                    try baseRead(target, required: "x30")
                case .intrinsic(nil, "nop", let args) where args.isEmpty && i.returnTarget == nil: break
                default: throw Failure.unsupported("broadcast untyped effect")
                }
            }
            position += 1
        }
    }
    mutating func executeNEONBroadcastMemory(_ frame: MacIRNEONBroadcastMemory) throws {
        let old = try evaluate(frame.oldBase)
        guard old.width == 64, old.kind != .float,
              old.bits <= UInt64.max - UInt64(frame.byteCount-1) else { throw Failure.unsupported("broadcast scalar span/base") }
        // Read exactly the scalar footprint. Full-Q does NOT authorize16 bytes.
        var scalar: UInt64 = 0
        for offset in 0..<frame.byteCount { scalar |= UInt64(state.byte(at: old.bits + UInt64(offset))) << (offset*8) }
        var low: UInt64 = 0, high: UInt64 = 0
        for lane in 0..<frame.laneCount {
            let byte = lane * frame.elementBytes
            if byte < 8 { low |= scalar << (byte*8) }
            else { high |= scalar << ((byte-8)*8) }
        }
        try writeNEONRegister(frame.destination, .init(bits: low, width: 128, kind: .unsigned, high: high))
        if let destination = frame.baseDestination {
            try write(destination, .int(old.bits &+ UInt64(frame.fixedPostDelta), width: 64, signed: false))
        }
    }
}

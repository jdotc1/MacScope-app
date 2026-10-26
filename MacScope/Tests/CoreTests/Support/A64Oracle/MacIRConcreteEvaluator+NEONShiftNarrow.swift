import Foundation
#if canImport(MacScope)
@testable import MacScope
#endif

extension MacIRConcreteEvaluator {
    /// Inspect the entire list, including every foreign composite interior, before
    /// dispatch. This route does not widen51's composition certificate or any family.
    func validateNEONShiftNarrow(_ list: [MacIRInstruction]) throws {
        guard !list.contains(where: { $0.neonLaneCoefficientProduct != nil || $0.neonReplicatedIndexedProduct != nil }) else { throw Failure.unsupported("replicated product marker in standalone family") }
        guard list.contains(where: { $0.neonShiftNarrow != nil }) else { return }
        guard (2...64).contains(list.count), list.last?.operation == .returnValue(nil),
              Set(list.map(\.id)).count == list.count,
              !function.parameters.contains(where: {
                  switch $0.abiLocation { case .simd, .entryStack: return true; default: return false }
              }) else { throw Failure.unsupported("shift narrow whole-list bound/identity/formals") }
        var versions: [String: Int] = [:], sequence = 0, loads = 0, stores = 0, previousPC: UInt64?
        func vector(_ value: MacIRValue, write: Bool) throws -> String {
            guard case let .register(name, version) = value, let n = A64MachineState.vectorIndex(name), name == "v\(n)",
                  version == versions[name, default: 0] + (write ? 1 : 0) else { throw Failure.unsupported("shift narrow current physical128 snapshot") }
            if write { versions[name] = version }; return name
        }
        func base(_ value: MacIRValue, required: String? = nil) throws {
            let name: String
            switch value {
            case let .register(n, version) where version == 0:
                guard !function.parameters.contains(where: { $0.register == n && $0.bindingID != nil }) else { throw Failure.unsupported("shift narrow bypassed formal") }
                name = n
            case let .argument(binding):
                guard binding.kind == .gpr, (0..<8).contains(binding.value),
                      function.parameters.filter({ $0.bindingID == binding }).count == 1,
                      let formal = function.parameters.first(where: { $0.bindingID == binding }),
                      formal.abiLocation == .gpr(index: binding.value, carrierWidth: 64) else { throw Failure.unsupported("shift narrow unbound/narrow base") }
                name = "x\(binding.value)"
            default: throw Failure.unsupported("shift narrow base/return shape")
            }
            guard let n = A64MachineState.gprIndex(name), n < 31, name == "x\(n)", required == nil || name == required else { throw Failure.unsupported("shift narrow base/return") }
        }
        for (position, i) in list.enumerated() {
            guard i.neonScalarVariableShift == nil, i.neonWiderChannelMemory == nil, i.neonMultiChannelLane == nil, i.neonWiderMultiChannelLane == nil, i.neonWiderMultiChannelReplicate == nil, i.neonScalarShiftCompilerComposition == nil, i.neonScalarMaskSelection == nil, i.neonScalarIntegerComparison == nil, i.neonMultiChannelReplicate == nil else { throw Failure.unsupported("new82 foreign metadata exclusion") }
            guard i.neonPredicate == nil, i.neonWideningPairwise == nil, i.neonMagnitudeClamp == nil, i.neonPairwise == nil, i.neonLaneMemory == nil, i.neonBroadcastMemory == nil,
                  i.neonBitCount == nil, i.neonOrderConversion == nil, i.neonInterleavedMemory == nil, i.neonIndexedMemory == nil,
                  i.neonBufferSequence == nil, i.neonBitView == nil, i.neonReduction == nil, i.neonPacking == nil,
                  i.neonImmediate == nil, i.neonMultiply == nil, i.neonShiftInsert == nil, i.neonLogical == nil,
                  i.neonExtract == nil, i.neonPermutation == nil, i.neonModular == nil, i.neonComparison == nil,
                  i.neonTableLookup == nil, i.scalarFP == nil else { throw Failure.unsupported("shift narrow competing metadata") }
            guard i.source.address.isMultiple(of: 4) else { throw Failure.unsupported("shift narrow PC alignment") }
            if let pc = previousPC { guard pc <= UInt64.max-4, i.source.address == pc+4 else { throw Failure.unsupported("shift narrow PC order") } }
            previousPC = i.source.address
            if let descriptor = i.neonShiftNarrow {
                guard i.neonScalarVariableShift == nil, i.neonWiderChannelMemory == nil, i.neonMultiChannelLane == nil, i.neonWiderMultiChannelLane == nil, i.neonWiderMultiChannelReplicate == nil, i.neonScalarShiftCompilerComposition == nil, i.neonScalarMaskSelection == nil, i.neonScalarIntegerComparison == nil, i.neonMultiChannelReplicate == nil else { throw Failure.unsupported("new82 foreign metadata exclusion") }
                guard i.neonBufferMemory == nil, i.memoryAccess == nil, i.returnTarget == nil,
                      case let .intrinsic(destination?, _, arguments) = i.operation, arguments.count == descriptor.arity else { throw Failure.unsupported("shift narrow typed shape") }
                _ = try vector(arguments[0], write: false)
                if descriptor.destinationHighHalf {
                    let oldName = try vector(arguments[1], write: false)
                    guard case let .register(destinationName, _) = destination, oldName == destinationName else { throw Failure.unsupported("shift narrow old destination role") }
                }
                _ = try vector(destination, write: true)
            } else if let memory = i.neonBufferMemory {
                guard memory.sequence == sequence, i.memoryAccess == .init(byteWidth: 16), i.returnTarget == nil else { throw Failure.unsupported("shift narrow Q access/order") }
                try base(memory.base)
                switch (memory.effect, i.operation) {
                case let (.load, .load(destination, address)) where address == memory.address: _ = try vector(destination, write: true)
                case let (.store, .store(source, address)) where address == memory.address: _ = try vector(source, write: false)
                default: throw Failure.unsupported("shift narrow Q shape")
                }
                sequence += 1; if memory.effect == .load { loads += 1 } else { stores += 1 }
            } else {
                guard i.memoryAccess == nil else { throw Failure.unsupported("shift narrow untyped memory") }
                switch i.operation {
                case .returnValue(nil) where position == list.count-1:
                    guard let target = i.returnTarget else { throw Failure.unsupported("shift narrow missing return") }
                    try base(target, required: "x30")
                case .intrinsic(nil, "nop", let arguments) where arguments.isEmpty && i.returnTarget == nil: break
                default: throw Failure.unsupported("shift narrow untyped effect")
                }
            }
        }
        guard sequence == 0 || (loads > 0 && stores > 0) else { throw Failure.unsupported("shift narrow incomplete buffer") }
    }
    mutating func executeNEONShiftNarrow(_ descriptor: MacIRNEONShiftNarrow, operation: MacIROperation) throws {
        guard case let .intrinsic(destination?, _, arguments) = operation, arguments.count == descriptor.arity else { throw Failure.unsupported("shift narrow intrinsic") }
        // Complete snapshots precede the write, including source==destination.
        let source = try readNEONRegister(arguments[0])
        let oldDestination = descriptor.destinationHighHalf ? try readNEONRegister(arguments[1]) : nil
        guard source.width == 128, oldDestination == nil || oldDestination?.width == 128 else { throw Failure.unsupported("shift narrow full128 captures") }
        let wideBits = descriptor.sourceLaneBits
        let wideMask = wideBits == 64 ? UInt64.max : (UInt64(1) << wideBits)-1
        let narrowMask = (UInt64(1) << descriptor.narrowBits)-1
        var packed: UInt64 = 0
        for lane in 0..<descriptor.laneCount {
            let offset = lane * wideBits
            let raw = ((offset < 64 ? source.bits : source.high) >> (offset % 64)) & wideMask
            // No signed shift, rounding, saturation or host shift-by64.
            let narrowed = (raw >> descriptor.shift) & narrowMask
            packed |= narrowed << (lane * descriptor.narrowBits)
        }
        let low = descriptor.destinationHighHalf ? oldDestination!.bits : packed
        let high: UInt64 = descriptor.destinationHighHalf ? packed : 0
        try writeNEONRegister(destination, .init(bits: low, width: 128, kind: .unsigned, high: high))
    }
}

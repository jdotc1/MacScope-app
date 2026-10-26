import Foundation
#if canImport(MacScope)
@testable import MacScope
#endif

extension MacIRConcreteEvaluator {
    /// Inspect the entire list, including every foreign composite interior, before
    /// dispatch. This route does not widen51's composition certificate or any family.
    func validateNEONWideningPairwise(_ list: [MacIRInstruction]) throws {
        guard !list.contains(where: { $0.neonLaneCoefficientProduct != nil || $0.neonReplicatedIndexedProduct != nil }) else { throw Failure.unsupported("replicated product marker in standalone family") }
        guard list.contains(where: { $0.neonWideningPairwise != nil }) else { return }
        guard (2...64).contains(list.count), list.last?.operation == .returnValue(nil),
              Set(list.map(\.id)).count == list.count,
              !function.parameters.contains(where: {
                  switch $0.abiLocation { case .simd, .entryStack: return true; default: return false }
              }) else { throw Failure.unsupported("widening pairwise whole-list bound/identity/formals") }
        var versions: [String: Int] = [:], sequence = 0, loads = 0, stores = 0, previousPC: UInt64?
        func vector(_ value: MacIRValue, write: Bool) throws -> String {
            guard case let .register(name, version) = value, let n = A64MachineState.vectorIndex(name), name == "v\(n)",
                  version == versions[name, default: 0] + (write ? 1 : 0) else { throw Failure.unsupported("widening pairwise current physical128 snapshot") }
            if write { versions[name] = version }; return name
        }
        func base(_ value: MacIRValue, required: String? = nil) throws {
            let name: String
            switch value {
            case let .register(n, version) where version == 0:
                guard !function.parameters.contains(where: { $0.register == n && $0.bindingID != nil }) else { throw Failure.unsupported("widening pairwise bypassed formal") }
                name = n
            case let .argument(binding):
                guard binding.kind == .gpr, (0..<8).contains(binding.value),
                      function.parameters.filter({ $0.bindingID == binding }).count == 1,
                      let formal = function.parameters.first(where: { $0.bindingID == binding }),
                      formal.abiLocation == .gpr(index: binding.value, carrierWidth: 64) else { throw Failure.unsupported("widening pairwise unbound/narrow base") }
                name = "x\(binding.value)"
            default: throw Failure.unsupported("widening pairwise base/return shape")
            }
            guard let n = A64MachineState.gprIndex(name), n < 31, name == "x\(n)", required == nil || name == required else { throw Failure.unsupported("widening pairwise base/return") }
        }
        for (position, i) in list.enumerated() {
            guard i.neonScalarVariableShift == nil, i.neonWiderChannelMemory == nil, i.neonMultiChannelLane == nil, i.neonWiderMultiChannelLane == nil, i.neonWiderMultiChannelReplicate == nil, i.neonScalarShiftCompilerComposition == nil, i.neonScalarMaskSelection == nil, i.neonScalarIntegerComparison == nil, i.neonMultiChannelReplicate == nil else { throw Failure.unsupported("new82 foreign metadata exclusion") }
            guard i.neonMagnitudeClamp == nil, i.neonPairwise == nil, i.neonLaneMemory == nil, i.neonBroadcastMemory == nil,
                  i.neonBitCount == nil, i.neonOrderConversion == nil, i.neonInterleavedMemory == nil, i.neonIndexedMemory == nil,
                  i.neonBufferSequence == nil, i.neonBitView == nil, i.neonReduction == nil, i.neonPacking == nil,
                  i.neonImmediate == nil, i.neonMultiply == nil, i.neonShiftInsert == nil, i.neonLogical == nil,
                  i.neonExtract == nil, i.neonPermutation == nil, i.neonModular == nil, i.neonComparison == nil,
                  i.neonTableLookup == nil, i.scalarFP == nil else { throw Failure.unsupported("widening pairwise competing metadata") }
            guard i.source.address.isMultiple(of: 4) else { throw Failure.unsupported("widening pairwise PC alignment") }
            if let pc = previousPC { guard pc <= UInt64.max-4, i.source.address == pc+4 else { throw Failure.unsupported("widening pairwise PC order") } }
            previousPC = i.source.address
            if let descriptor = i.neonWideningPairwise {
                guard i.neonScalarVariableShift == nil, i.neonWiderChannelMemory == nil, i.neonMultiChannelLane == nil, i.neonWiderMultiChannelLane == nil, i.neonWiderMultiChannelReplicate == nil, i.neonScalarShiftCompilerComposition == nil, i.neonScalarMaskSelection == nil, i.neonScalarIntegerComparison == nil, i.neonMultiChannelReplicate == nil else { throw Failure.unsupported("new82 foreign metadata exclusion") }
                guard i.neonBufferMemory == nil, i.memoryAccess == nil, i.returnTarget == nil,
                      case let .intrinsic(destination?, _, arguments) = i.operation, arguments.count == descriptor.arity else { throw Failure.unsupported("widening pairwise typed shape") }
                _ = try vector(arguments[0], write: false)
                if descriptor.accumulates {
                    let oldName = try vector(arguments[1], write: false)
                    guard case let .register(destinationName, _) = destination, oldName == destinationName else { throw Failure.unsupported("widening pairwise old destination role") }
                }
                _ = try vector(destination, write: true)
            } else if let memory = i.neonBufferMemory {
                guard memory.sequence == sequence, i.memoryAccess == .init(byteWidth: 16), i.returnTarget == nil else { throw Failure.unsupported("widening pairwise Q access/order") }
                try base(memory.base)
                switch (memory.effect, i.operation) {
                case let (.load, .load(destination, address)) where address == memory.address: _ = try vector(destination, write: true)
                case let (.store, .store(source, address)) where address == memory.address: _ = try vector(source, write: false)
                default: throw Failure.unsupported("widening pairwise Q shape")
                }
                sequence += 1; if memory.effect == .load { loads += 1 } else { stores += 1 }
            } else {
                guard i.memoryAccess == nil else { throw Failure.unsupported("widening pairwise untyped memory") }
                switch i.operation {
                case .returnValue(nil) where position == list.count-1:
                    guard let target = i.returnTarget else { throw Failure.unsupported("widening pairwise missing return") }
                    try base(target, required: "x30")
                case .intrinsic(nil, "nop", let arguments) where arguments.isEmpty && i.returnTarget == nil: break
                default: throw Failure.unsupported("widening pairwise untyped effect")
                }
            }
        }
        guard sequence == 0 || (loads > 0 && stores > 0) else { throw Failure.unsupported("widening pairwise incomplete buffer") }
    }
    mutating func executeNEONWideningPairwise(_ descriptor: MacIRNEONWideningPairwise, operation: MacIROperation) throws {
        guard case let .intrinsic(destination?, _, arguments) = operation, arguments.count == descriptor.arity else { throw Failure.unsupported("widening pairwise intrinsic") }
        let narrow = try readNEONRegister(arguments[0])
        let oldDestination = descriptor.accumulates ? try readNEONRegister(arguments[1]) : nil
        guard narrow.width == 128, oldDestination == nil || oldDestination?.width == 128 else { throw Failure.unsupported("widening pairwise full128 captures") }
        let sourceBits = descriptor.sourceElementBytes * 8, destinationBits = sourceBits * 2
        let sourceMask = (UInt64(1) << sourceBits)-1
        let destinationMask = destinationBits == 64 ? UInt64.max : (UInt64(1) << destinationBits)-1
        let sign = UInt64(1) << (sourceBits-1)
        var low: UInt64 = 0, high: UInt64 = 0
        for lane in 0..<descriptor.destinationLaneCount {
            func extended(_ inputLane: Int) -> UInt64 {
                let shift = inputLane * sourceBits
                let bits = ((shift < 64 ? narrow.bits : narrow.high) >> (shift % 64)) & sourceMask
                // Extend EACH input before adding, using only unsigned bit patterns.
                return descriptor.isSigned && bits & sign != 0 ? bits | (destinationMask ^ sourceMask) : bits
            }
            let shift = lane * destinationBits
            let prior: UInt64
            if let oldDestination { prior = ((shift < 64 ? oldDestination.bits : oldDestination.high) >> (shift % 64)) & destinationMask }
            else { prior = 0 }
            // Modular destination-width arithmetic never invokes host signed overflow.
            let value = (extended(lane*2) &+ extended(lane*2+1) &+ prior) & destinationMask
            if shift < 64 { low |= value << shift } else { high |= value << (shift-64) }
        }
        // Q0 writes still define a complete physical128 value, clearing high64.
        try writeNEONRegister(destination, .init(bits: low, width: 128, kind: .unsigned, high: high))
    }
}

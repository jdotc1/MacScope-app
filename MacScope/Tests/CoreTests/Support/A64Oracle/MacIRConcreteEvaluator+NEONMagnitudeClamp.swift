import Foundation
#if canImport(MacScope)
@testable import MacScope
#endif

extension MacIRConcreteEvaluator {
    /// Full-list preflight does not skip foreign frame interiors.
    func validateNEONMagnitudeClamp(_ list: [MacIRInstruction]) throws {
        guard !list.contains(where: { $0.neonLaneCoefficientProduct != nil || $0.neonReplicatedIndexedProduct != nil }) else { throw Failure.unsupported("replicated product marker in standalone family") }
        guard list.contains(where: { $0.neonMagnitudeClamp != nil }) else { return }
        guard (2...64).contains(list.count), let last = list.last,
              case .returnValue(nil) = last.operation else { throw Failure.unsupported("magnitude/clamp budget/terminal") }
        var versions: [String: Int] = [:], sequence = 0, loads = 0, stores = 0
        func vector(_ value: MacIRValue, write: Bool) throws {
            guard case let .register(name, version) = value, let n = A64MachineState.vectorIndex(name),
                  name == "v\(n)", version == versions[name, default: 0] + (write ? 1 : 0) else {
                throw Failure.unsupported("magnitude/clamp current canonical snapshot")
            }
            if write { versions[name] = version }
        }
        func base(_ value: MacIRValue, required: String? = nil) throws {
            let name: String
            switch value {
            case let .register(n, v) where v == 0: name = n
            case let .argument(binding) where binding.kind == .gpr: name = "x\(binding.value)"
            default: throw Failure.unsupported("magnitude/clamp base shape")
            }
            guard let n = A64MachineState.gprIndex(name), n < 31, name == "x\(n)",
                  required == nil || name == required else { throw Failure.unsupported("magnitude/clamp base/return") }
        }
        for (position, i) in list.enumerated() {
            guard i.neonScalarVariableShift == nil, i.neonWiderChannelMemory == nil, i.neonMultiChannelLane == nil, i.neonWiderMultiChannelLane == nil, i.neonWiderMultiChannelReplicate == nil, i.neonScalarShiftCompilerComposition == nil, i.neonScalarMaskSelection == nil, i.neonScalarIntegerComparison == nil, i.neonMultiChannelReplicate == nil else { throw Failure.unsupported("new82 foreign metadata exclusion") }
            guard i.neonPairwise == nil, i.neonLaneMemory == nil, i.neonBroadcastMemory == nil, i.neonBitCount == nil,
                  i.neonOrderConversion == nil, i.neonInterleavedMemory == nil, i.neonIndexedMemory == nil,
                  i.neonBufferSequence == nil, i.neonBitView == nil, i.neonReduction == nil,
                  i.neonPacking == nil, i.neonImmediate == nil, i.neonMultiply == nil,
                  i.neonShiftInsert == nil, i.neonLogical == nil, i.neonExtract == nil,
                  i.neonPermutation == nil, i.neonModular == nil, i.neonComparison == nil,
                  i.neonTableLookup == nil, i.scalarFP == nil else { throw Failure.unsupported("magnitude/clamp competing family") }
            if let descriptor = i.neonMagnitudeClamp {
                guard i.neonScalarVariableShift == nil, i.neonWiderChannelMemory == nil, i.neonMultiChannelLane == nil, i.neonWiderMultiChannelLane == nil, i.neonWiderMultiChannelReplicate == nil, i.neonScalarShiftCompilerComposition == nil, i.neonScalarMaskSelection == nil, i.neonScalarIntegerComparison == nil, i.neonMultiChannelReplicate == nil else { throw Failure.unsupported("new82 foreign metadata exclusion") }
                guard i.neonBufferMemory == nil, i.memoryAccess == nil, i.returnTarget == nil,
                      case let .intrinsic(destination?, _, arguments) = i.operation, arguments.count == descriptor.arity else { throw Failure.unsupported("magnitude/clamp shape") }
                // Read both at the same pre-write version, including all-register aliases.
                for source in arguments { try vector(source, write: false) }
                try vector(destination, write: true)
            } else if let memory = i.neonBufferMemory {
                guard memory.sequence == sequence, i.memoryAccess == .init(byteWidth: 16), i.returnTarget == nil else { throw Failure.unsupported("magnitude/clamp Q access/order") }
                try base(memory.base)
                switch (memory.effect, i.operation) {
                case let (.load, .load(destination, address)) where address == memory.address: try vector(destination, write: true)
                case let (.store, .store(source, address)) where address == memory.address: try vector(source, write: false)
                default: throw Failure.unsupported("magnitude/clamp Q shape")
                }
                sequence += 1; if memory.effect == .load { loads += 1 } else { stores += 1 }
            } else {
                guard i.memoryAccess == nil else { throw Failure.unsupported("magnitude/clamp untyped memory") }
                switch i.operation {
                case .returnValue(nil) where position == list.count-1:
                    guard let target = i.returnTarget else { throw Failure.unsupported("magnitude/clamp missing return") }
                    try base(target, required: "x30")
                case .intrinsic(nil, "nop", let args) where args.isEmpty && i.returnTarget == nil: break
                default: throw Failure.unsupported("magnitude/clamp untyped effect")
                }
            }
        }
        guard sequence == 0 || (loads > 0 && stores > 0) else { throw Failure.unsupported("magnitude/clamp incomplete buffer") }
    }
    mutating func executeNEONMagnitudeClamp(_ descriptor: MacIRNEONMagnitudeClamp, operation: MacIROperation) throws {
        guard case let .intrinsic(destination?, _, arguments) = operation, arguments.count == descriptor.arity else { throw Failure.unsupported("magnitude/clamp intrinsic") }
        let sources = try arguments.map { try readNEONRegister($0) }
        guard sources.allSatisfy({ $0.width == 128 }) else { throw Failure.unsupported("magnitude/clamp source width") }
        let bits = descriptor.elementBytes * 8, mask = bits == 64 ? UInt64.max : (UInt64(1) << bits) - 1
        let sign = UInt64(1) << (bits-1)
        var low: UInt64 = 0, high: UInt64 = 0
        for lane in 0..<descriptor.laneCount {
            let shift = lane * bits
            func value(_ source: Int) -> UInt64 { ((shift < 64 ? sources[source].bits : sources[source].high) >> (shift % 64)) & mask }
            let a = value(0), b = descriptor.arity == 2 ? value(1) : 0, result: UInt64
            switch descriptor.kind {
            case .abs: result = a & sign == 0 ? a : (UInt64(0) &- a) & mask
            case .neg: result = (UInt64(0) &- a) & mask
            case .smin: result = (a ^ sign) < (b ^ sign) ? a : b
            case .smax: result = (a ^ sign) > (b ^ sign) ? a : b
            case .umin: result = min(a,b)
            case .umax: result = max(a,b)
            }
            if shift < 64 { low |= result << shift } else { high |= result << (shift-64) }
        }
        // Unsigned-bit subtraction preserves signed-min wrap even for D lanes.
        // The untouched initialized high half is architectural Q0 zero clearing.
        try writeNEONRegister(destination, .init(bits: low, width: 128, kind: .unsigned, high: high))
    }
}

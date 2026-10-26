import Foundation
#if canImport(MacScope)
@testable import MacScope
#endif

extension MacIRConcreteEvaluator {
    /// Full-list preflight does not skip foreign frame interiors.
    func validateNEONPairwise(_ list: [MacIRInstruction]) throws {
        guard !list.contains(where: { $0.neonLaneCoefficientProduct != nil || $0.neonReplicatedIndexedProduct != nil }) else { throw Failure.unsupported("replicated product marker in standalone family") }
        guard list.contains(where: { $0.neonPairwise != nil }) else { return }
        guard (2...64).contains(list.count), let last = list.last,
              case .returnValue(nil) = last.operation else { throw Failure.unsupported("pairwise budget/terminal") }
        var versions: [String: Int] = [:], sequence = 0
        func vector(_ value: MacIRValue, write: Bool) throws {
            guard case let .register(name, version) = value, let n = A64MachineState.vectorIndex(name),
                  name == "v\(n)", version == versions[name, default: 0] + (write ? 1 : 0) else {
                throw Failure.unsupported("pairwise current canonical snapshot")
            }
            if write { versions[name] = version }
        }
        func base(_ value: MacIRValue, required: String? = nil) throws {
            let name: String
            switch value {
            case let .register(n, v) where v == 0: name = n
            case let .argument(binding) where binding.kind == .gpr: name = "x\(binding.value)"
            default: throw Failure.unsupported("pairwise base shape")
            }
            guard let n = A64MachineState.gprIndex(name), n < 31, name == "x\(n)",
                  required == nil || name == required else { throw Failure.unsupported("pairwise base/return") }
        }
        for (position, i) in list.enumerated() {
            guard i.neonScalarVariableShift == nil, i.neonWiderChannelMemory == nil, i.neonMultiChannelLane == nil, i.neonWiderMultiChannelLane == nil, i.neonWiderMultiChannelReplicate == nil, i.neonScalarShiftCompilerComposition == nil, i.neonScalarMaskSelection == nil, i.neonScalarIntegerComparison == nil, i.neonMultiChannelReplicate == nil else { throw Failure.unsupported("new82 foreign metadata exclusion") }
            guard i.neonLaneMemory == nil, i.neonBroadcastMemory == nil, i.neonBitCount == nil,
                  i.neonOrderConversion == nil, i.neonInterleavedMemory == nil, i.neonIndexedMemory == nil,
                  i.neonBufferSequence == nil, i.neonBitView == nil, i.neonReduction == nil,
                  i.neonPacking == nil, i.neonImmediate == nil, i.neonMultiply == nil,
                  i.neonShiftInsert == nil, i.neonLogical == nil, i.neonExtract == nil,
                  i.neonPermutation == nil, i.neonModular == nil, i.neonComparison == nil,
                  i.neonTableLookup == nil, i.scalarFP == nil else { throw Failure.unsupported("pairwise competing family") }
            if i.neonPairwise != nil {
                guard i.neonScalarVariableShift == nil, i.neonWiderChannelMemory == nil, i.neonMultiChannelLane == nil, i.neonWiderMultiChannelLane == nil, i.neonWiderMultiChannelReplicate == nil, i.neonScalarShiftCompilerComposition == nil, i.neonScalarMaskSelection == nil, i.neonScalarIntegerComparison == nil, i.neonMultiChannelReplicate == nil else { throw Failure.unsupported("new82 foreign metadata exclusion") }
                guard i.neonBufferMemory == nil, i.memoryAccess == nil, i.returnTarget == nil,
                      case let .intrinsic(destination?, _, arguments) = i.operation, arguments.count == 2 else { throw Failure.unsupported("pairwise shape") }
                // Read both at the same pre-write version, including all-register aliases.
                for source in arguments { try vector(source, write: false) }
                try vector(destination, write: true)
            } else if let memory = i.neonBufferMemory {
                guard memory.sequence == sequence, i.memoryAccess == .init(byteWidth: 16), i.returnTarget == nil else { throw Failure.unsupported("pairwise Q access/order") }
                try base(memory.base)
                switch (memory.effect, i.operation) {
                case let (.load, .load(destination, address)) where address == memory.address: try vector(destination, write: true)
                case let (.store, .store(source, address)) where address == memory.address: try vector(source, write: false)
                default: throw Failure.unsupported("pairwise Q shape")
                }
                sequence += 1
            } else {
                guard i.memoryAccess == nil else { throw Failure.unsupported("pairwise untyped memory") }
                switch i.operation {
                case .returnValue(nil) where position == list.count-1:
                    guard let target = i.returnTarget else { throw Failure.unsupported("pairwise missing return") }
                    try base(target, required: "x30")
                case .intrinsic(nil, "nop", let args) where args.isEmpty && i.returnTarget == nil: break
                default: throw Failure.unsupported("pairwise untyped effect")
                }
            }
        }
    }
    mutating func executeNEONPairwise(_ descriptor: MacIRNEONPairwise, operation: MacIROperation) throws {
        guard case let .intrinsic(destination?, _, arguments) = operation, arguments.count == 2 else { throw Failure.unsupported("pairwise intrinsic") }
        let lhs = try readNEONRegister(arguments[0]), rhs = try readNEONRegister(arguments[1])
        guard lhs.width == 128, rhs.width == 128 else { throw Failure.unsupported("pairwise source width") }
        let bits = descriptor.elementBytes * 8, mask = bits == 64 ? UInt64.max : (UInt64(1) << bits) - 1
        let sign = UInt64(1) << (bits-1), half = descriptor.laneCount / 2
        var low: UInt64 = 0, high: UInt64 = 0
        for outputLane in 0..<descriptor.laneCount {
            let source = outputLane < half ? lhs : rhs
            let inputLane = (outputLane % half) * 2
            func lane(_ n: Int) -> UInt64 { let shift = n * bits; return ((shift < 64 ? source.bits : source.high) >> (shift % 64)) & mask }
            let a = lane(inputLane), b = lane(inputLane+1), value: UInt64
            switch descriptor.kind {
            case .addp: value = (a &+ b) & mask
            case .sminp: value = (a ^ sign) < (b ^ sign) ? a : b
            case .smaxp: value = (a ^ sign) > (b ^ sign) ? a : b
            case .uminp: value = min(a,b)
            case .umaxp: value = max(a,b)
            }
            let shift = outputLane * bits
            if shift < 64 { low |= value << shift } else { high |= value << (shift-64) }
        }
        try writeNEONRegister(destination, .init(bits: low, width: 128, kind: .unsigned, high: high))
    }
}

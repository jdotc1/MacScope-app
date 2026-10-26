import Foundation
#if canImport(MacScope)
@testable import MacScope
#endif

extension MacIRConcreteEvaluator {
    /// Run after56 certificate construction but before all payload. Examine every
    /// interior, so a foreign composition cannot hide a new typed operation.
    func validateNEONWideningAddSubtract(_ list: [MacIRInstruction]) throws {
        guard !list.contains(where: { $0.neonLaneCoefficientProduct != nil || $0.neonReplicatedIndexedProduct != nil }) else { throw Failure.unsupported("replicated product marker in standalone family") }
        guard list.contains(where: { $0.neonWideningAddSubtract != nil }) else { return }
        guard (2...64).contains(list.count), list.last?.operation == .returnValue(nil),
              Set(list.map(\.id)).count == list.count,
              !function.parameters.contains(where: {
                  switch $0.abiLocation { case .simd, .entryStack: return true; default: return false }
              }) else { throw Failure.unsupported("widening add subtract whole-list bound/identity/formals") }
        var versions: [String: Int] = [:], sequence = 0, loads = 0, stores = 0, previousPC: UInt64?
        func vector(_ value: MacIRValue, write: Bool) throws {
            guard case let .register(name, version) = value, let n = A64MachineState.vectorIndex(name), name == "v\(n)",
                  version == versions[name, default: 0] + (write ? 1 : 0) else { throw Failure.unsupported("widening add subtract current physical128 snapshot") }
            if write { versions[name] = version }
        }
        func base(_ value: MacIRValue, required: String? = nil) throws {
            let name: String
            switch value {
            case let .register(n, version) where version == 0:
                guard !function.parameters.contains(where: { $0.register == n && $0.bindingID != nil }) else { throw Failure.unsupported("widening add subtract bypassed formal") }
                name = n
            case let .argument(binding):
                guard binding.kind == .gpr, (0..<8).contains(binding.value),
                      function.parameters.filter({ $0.bindingID == binding }).count == 1,
                      let formal = function.parameters.first(where: { $0.bindingID == binding }),
                      formal.abiLocation == .gpr(index: binding.value, carrierWidth: 64) else { throw Failure.unsupported("widening add subtract unbound/narrow base") }
                name = "x\(binding.value)"
            default: throw Failure.unsupported("widening add subtract base/return shape")
            }
            guard let n = A64MachineState.gprIndex(name), n < 31, name == "x\(n)", required == nil || name == required else { throw Failure.unsupported("widening add subtract base/return") }
        }
        for (position, i) in list.enumerated() {
            guard i.neonScalarVariableShift == nil, i.neonWiderChannelMemory == nil, i.neonMultiChannelLane == nil, i.neonWiderMultiChannelLane == nil, i.neonWiderMultiChannelReplicate == nil, i.neonScalarShiftCompilerComposition == nil, i.neonScalarMaskSelection == nil, i.neonScalarIntegerComparison == nil, i.neonMultiChannelReplicate == nil else { throw Failure.unsupported("new82 foreign metadata exclusion") }
            guard i.neonContiguousGroup == nil, i.neonShiftNarrow == nil, i.neonPredicate == nil,
                  i.neonWideningPairwise == nil, i.neonMagnitudeClamp == nil, i.neonPairwise == nil,
                  i.neonLaneMemory == nil, i.neonBroadcastMemory == nil, i.neonBitCount == nil,
                  i.neonOrderConversion == nil, i.neonInterleavedMemory == nil, i.neonIndexedMemory == nil,
                  i.neonBufferSequence == nil, i.neonBitView == nil, i.neonReduction == nil, i.neonPacking == nil,
                  i.neonImmediate == nil, i.neonMultiply == nil, i.neonShiftInsert == nil, i.neonLogical == nil,
                  i.neonExtract == nil, i.neonPermutation == nil, i.neonModular == nil, i.neonComparison == nil,
                  i.neonTableLookup == nil, i.scalarFP == nil else { throw Failure.unsupported("widening add subtract competing metadata") }
            guard i.source.address.isMultiple(of: 4) else { throw Failure.unsupported("widening add subtract PC alignment") }
            if let pc = previousPC { guard pc <= UInt64.max-4, i.source.address == pc+4 else { throw Failure.unsupported("widening add subtract PC order") } }
            previousPC = i.source.address
            if i.neonWideningAddSubtract != nil {
                guard i.neonScalarVariableShift == nil, i.neonWiderChannelMemory == nil, i.neonMultiChannelLane == nil, i.neonWiderMultiChannelLane == nil, i.neonWiderMultiChannelReplicate == nil, i.neonScalarShiftCompilerComposition == nil, i.neonScalarMaskSelection == nil, i.neonScalarIntegerComparison == nil, i.neonMultiChannelReplicate == nil else { throw Failure.unsupported("new82 foreign metadata exclusion") }
                guard i.neonBufferMemory == nil, i.memoryAccess == nil, i.returnTarget == nil,
                      case let .intrinsic(destination?, _, arguments) = i.operation, arguments.count == 2 else { throw Failure.unsupported("widening add subtract typed shape") }
                try vector(arguments[0], write: false); try vector(arguments[1], write: false)
                try vector(destination, write: true)
            } else if let memory = i.neonBufferMemory {
                guard memory.sequence == sequence, i.memoryAccess == .init(byteWidth: 16), i.returnTarget == nil else { throw Failure.unsupported("widening add subtract Q access/order") }
                try base(memory.base)
                switch (memory.effect, i.operation) {
                case let (.load, .load(destination, address)) where address == memory.address: try vector(destination, write: true)
                case let (.store, .store(source, address)) where address == memory.address: try vector(source, write: false)
                default: throw Failure.unsupported("widening add subtract Q shape")
                }
                sequence += 1; if memory.effect == .load { loads += 1 } else { stores += 1 }
            } else {
                guard i.memoryAccess == nil else { throw Failure.unsupported("widening add subtract untyped memory") }
                switch i.operation {
                case .returnValue(nil) where position == list.count-1:
                    guard let target = i.returnTarget else { throw Failure.unsupported("widening add subtract missing return") }
                    try base(target, required: "x30")
                case .intrinsic(nil, "nop", let arguments) where arguments.isEmpty && i.returnTarget == nil: break
                default: throw Failure.unsupported("widening add subtract untyped effect")
                }
            }
        }
        guard sequence == 0 || (loads > 0 && stores > 0) else { throw Failure.unsupported("widening add subtract incomplete buffer") }
    }
    mutating func executeNEONWideningAddSubtract(_ descriptor: MacIRNEONWideningAddSubtract, operation: MacIROperation) throws {
        guard case let .intrinsic(destination?, _, arguments) = operation, arguments.count == 2 else { throw Failure.unsupported("widening add subtract intrinsic") }
        let first = try readNEONRegister(arguments[0]), second = try readNEONRegister(arguments[1])
        guard first.width == 128, second.width == 128 else { throw Failure.unsupported("widening add subtract full128 captures") }
        let outputBits = descriptor.outputLaneBits
        let outputMask = outputBits == 64 ? UInt64.max : (UInt64(1) << outputBits)-1
        func lane(_ value: Scalar, _ role: MacIRNEONWideningAddSubtract.SourceRole, _ index: Int) -> UInt64 {
            let mask = role.laneBits == 64 ? UInt64.max : (UInt64(1) << role.laneBits)-1
            let offset = index * role.laneBits + (role.highHalf ? 64 : 0)
            let bits = ((offset < 64 ? value.bits : value.high) >> (offset % 64)) & mask
            return role.signed && bits & (UInt64(1) << (role.laneBits-1)) != 0 ? bits | (outputMask ^ mask) : bits
        }
        var low: UInt64 = 0, high: UInt64 = 0
        for index in 0..<descriptor.laneCount {
            let a = lane(first, descriptor.firstSource, index), b = lane(second, descriptor.secondSource, index)
            let result = (descriptor.kind == .ssubl ? a &- b : a &+ b) & outputMask
            let offset = index * outputBits
            if offset < 64 { low |= result << offset } else { high |= result << (offset-64) }
        }
        try writeNEONRegister(destination, .init(bits: low, width: 128, kind: .unsigned, high: high))
    }
}

import Foundation
#if canImport(MacScope)
@testable import MacScope
#endif

extension MacIRConcreteEvaluator {
    /// Run before all composition certificates and payload. Examine every
    /// interior, so a foreign composition cannot hide a new typed operation.
    func validateNEONFullWidthShift(_ list: [MacIRInstruction]) throws {
        guard !list.contains(where: { $0.neonLaneCoefficientProduct != nil || $0.neonReplicatedIndexedProduct != nil }) else { throw Failure.unsupported("replicated product marker in standalone family") }
        guard list.contains(where: { $0.neonFullWidthShift != nil }) else { return }
        guard (2...64).contains(list.count), list.last?.operation == .returnValue(nil),
              Set(list.map(\.id)).count == list.count,
              !function.parameters.contains(where: {
                  switch $0.abiLocation { case .simd, .entryStack: return true; default: return false }
              }) else { throw Failure.unsupported("full-width shift whole-list bound/identity/formals") }
        var physicalFormals: Set<Int> = []
        for formal in function.parameters {
            guard case let .gpr(index, width) = formal.abiLocation, (0..<8).contains(index), width == 64,
                  formal.bindingID == .gpr(index), physicalFormals.insert(index).inserted else { throw Failure.unsupported("full-width shift unique exact64 physical formals") }
        }
        var versions: [String: Int] = [:], sequence = 0, loads = 0, stores = 0, previousPC: UInt64?
        func vector(_ value: MacIRValue, write: Bool) throws {
            guard case let .register(name, version) = value, let n = A64MachineState.vectorIndex(name), name == "v\(n)",
                  version == versions[name, default: 0] + (write ? 1 : 0) else { throw Failure.unsupported("full-width shift current physical128 snapshot") }
            if write { versions[name] = version }
        }
        func base(_ value: MacIRValue, required: String? = nil) throws {
            let name: String
            switch value {
            case let .register(n, version) where version == 0:
                guard let index = A64MachineState.gprIndex(n), index < 31,
                      !function.parameters.contains(where: { formal in
                          if case let .gpr(formalIndex, _) = formal.abiLocation, formalIndex == index { return true }
                          guard let binding = formal.bindingID else { return false }
                          return binding.kind == .gpr && binding.value == index
                      }) else { throw Failure.unsupported("full-width shift bypassed physical GPR formal") }
                name = n
            case let .argument(binding):
                guard binding.kind == .gpr, (0..<8).contains(binding.value),
                      function.parameters.filter({ formal in
                          if case let .gpr(index, _) = formal.abiLocation, index == binding.value { return true }
                          return formal.bindingID == binding
                      }).count == 1,
                      let formal = function.parameters.first(where: { $0.bindingID == binding }),
                      formal.abiLocation == .gpr(index: binding.value, carrierWidth: 64) else { throw Failure.unsupported("full-width shift unbound/narrow base") }
                name = "x\(binding.value)"
            default: throw Failure.unsupported("full-width shift base/return shape")
            }
            guard let n = A64MachineState.gprIndex(name), n < 31, name == "x\(n)", required == nil || name == required else { throw Failure.unsupported("full-width shift base/return") }
        }
        for (position, i) in list.enumerated() {
            guard i.neonScalarVariableShift == nil, i.neonWiderChannelMemory == nil, i.neonMultiChannelLane == nil, i.neonWiderMultiChannelLane == nil, i.neonWiderMultiChannelReplicate == nil, i.neonScalarShiftCompilerComposition == nil, i.neonScalarMaskSelection == nil, i.neonScalarIntegerComparison == nil, i.neonMultiChannelReplicate == nil else { throw Failure.unsupported("new82 foreign metadata exclusion") }
            guard i.neonMixedByteDotProduct == nil, i.neonByteMatrixAccumulate == nil, i.neonIndexedMixedByteDotProduct == nil, i.neonSelectedWideningAccumulate == nil, i.neonIndexedByteDotProduct == nil, i.neonByteDotProduct == nil, i.neonSelectedSignedMultiply == nil, i.neonSelectedUnsignedMultiply == nil, i.neonBytePolynomialMultiply == nil, i.neonRoundedShift == nil, i.neonThreeChannelMemory == nil, i.neonSignedLongMultiply == nil, i.neonWideningAddSubtract == nil, i.neonContiguousGroup == nil, i.neonShiftNarrow == nil, i.neonPredicate == nil,
                  i.neonWideningPairwise == nil, i.neonMagnitudeClamp == nil, i.neonPairwise == nil,
                  i.neonLaneMemory == nil, i.neonBroadcastMemory == nil, i.neonBitCount == nil,
                  i.neonOrderConversion == nil, i.neonInterleavedMemory == nil, i.neonIndexedMemory == nil,
                  i.neonBufferSequence == nil, i.neonBitView == nil, i.neonReduction == nil, i.neonPacking == nil,
                  i.neonImmediate == nil, i.neonMultiply == nil, i.neonShiftInsert == nil, i.neonLogical == nil,
                  i.neonExtract == nil, i.neonPermutation == nil, i.neonModular == nil, i.neonComparison == nil,
                  i.neonTableLookup == nil, i.scalarFP == nil,
                  i.id == .init(sourceAddress: i.source.address, effectOrdinal: 0) else { throw Failure.unsupported("full-width shift competing metadata") }
            guard i.source.address.isMultiple(of: 4) else { throw Failure.unsupported("full-width shift PC alignment") }
            if let pc = previousPC { guard pc <= UInt64.max-4, i.source.address == pc+4 else { throw Failure.unsupported("full-width shift PC order") } }
            previousPC = i.source.address
            if i.neonFullWidthShift != nil {
                guard i.neonScalarVariableShift == nil, i.neonWiderChannelMemory == nil, i.neonMultiChannelLane == nil, i.neonWiderMultiChannelLane == nil, i.neonWiderMultiChannelReplicate == nil, i.neonScalarShiftCompilerComposition == nil, i.neonScalarMaskSelection == nil, i.neonScalarIntegerComparison == nil, i.neonMultiChannelReplicate == nil else { throw Failure.unsupported("new82 foreign metadata exclusion") }
                guard i.neonBufferMemory == nil, i.memoryAccess == nil, i.returnTarget == nil,
                      case let .intrinsic(destination?, _, arguments) = i.operation, arguments.count == 1 else { throw Failure.unsupported("full-width shift typed shape") }
                try vector(arguments[0], write: false)
                try vector(destination, write: true)
            } else if let memory = i.neonBufferMemory {
                guard memory.sequence == sequence, i.memoryAccess == .init(byteWidth: 16), i.returnTarget == nil else { throw Failure.unsupported("full-width shift Q access/order") }
                try base(memory.base)
                switch (memory.effect, i.operation) {
                case let (.load, .load(destination, address)) where address == memory.address: try vector(destination, write: true)
                case let (.store, .store(source, address)) where address == memory.address: try vector(source, write: false)
                default: throw Failure.unsupported("full-width shift Q shape")
                }
                sequence += 1; if memory.effect == .load { loads += 1 } else { stores += 1 }
            } else {
                guard i.memoryAccess == nil else { throw Failure.unsupported("full-width shift untyped memory") }
                switch i.operation {
                case .returnValue(nil) where position == list.count-1:
                    guard let target = i.returnTarget else { throw Failure.unsupported("full-width shift missing return") }
                    try base(target, required: "x30")
                case .intrinsic(nil, "nop", let arguments) where arguments.isEmpty && i.returnTarget == nil: break
                default: throw Failure.unsupported("full-width shift untyped effect")
                }
            }
        }
        guard sequence == 0 || (loads > 0 && stores > 0) else { throw Failure.unsupported("full-width shift incomplete buffer") }
    }
    mutating func executeNEONFullWidthShift(_ descriptor: MacIRNEONFullWidthShift, operation: MacIROperation) throws {
        guard case let .intrinsic(destination?, _, arguments) = operation, arguments.count == 1 else { throw Failure.unsupported("full-width shift intrinsic") }
        // Read complete physical128 before any write, including Vd == Vn.
        let source = try readNEONRegister(arguments[0])
        guard source.width == descriptor.sourceBits else { throw Failure.unsupported("full-width shift physical128 capture") }
        let bits = descriptor.narrowBits, wide = descriptor.outputLaneBits
        let mask = (UInt64(1) << bits)-1
        let selected = descriptor.sourceHighHalf ? source.high : source.bits
        var low: UInt64 = 0, high: UInt64 = 0
        for lane in 0..<descriptor.laneCount {
            // Zero-extend BEFORE shifting. No narrow-host shift or signed fill.
            let narrow = (selected >> (lane * bits)) & mask
            let value = narrow << descriptor.shift
            let offset = lane * wide
            if offset < 64 { low |= value << offset } else { high |= value << (offset-64) }
        }
        // Full overwrite, including both high-source forms and output64 lanes.
        try writeNEONRegister(destination, .init(bits: low, width: descriptor.outputBits, kind: .unsigned, high: high))
    }
}

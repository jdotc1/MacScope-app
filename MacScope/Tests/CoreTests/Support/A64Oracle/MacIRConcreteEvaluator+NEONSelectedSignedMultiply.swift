import Foundation
#if canImport(MacScope)
@testable import MacScope
#endif

extension MacIRConcreteEvaluator {
    /// Run before all composition certificates and payload. Examine every
    /// interior, so a foreign composition cannot hide a new typed operation.
    func validateNEONSelectedSignedMultiply(_ list: [MacIRInstruction]) throws {
        guard !list.contains(where: { $0.neonLaneCoefficientProduct != nil || $0.neonReplicatedIndexedProduct != nil }) else { throw Failure.unsupported("replicated product marker in standalone family") }
        guard list.contains(where: { $0.neonSelectedSignedMultiply != nil }) else { return }
        guard (2...64).contains(list.count), list.last?.operation == .returnValue(nil),
              Set(list.map(\.id)).count == list.count,
              !function.parameters.contains(where: {
                  switch $0.abiLocation { case .simd, .entryStack: return true; default: return false }
              }) else { throw Failure.unsupported("selected signed multiply whole-list bound/identity/formals") }
        var versions: [String: Int] = [:], sequence = 0, loads = 0, stores = 0, previousPC: UInt64?
        func vector(_ value: MacIRValue, write: Bool) throws {
            guard case let .register(name, version) = value, let n = A64MachineState.vectorIndex(name), name == "v\(n)",
                  version == versions[name, default: 0] + (write ? 1 : 0) else { throw Failure.unsupported("selected signed multiply current physical128 snapshot") }
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
                      }) else { throw Failure.unsupported("selected signed multiply bypassed physical GPR formal") }
                name = n
            case let .argument(binding):
                guard binding.kind == .gpr, (0..<8).contains(binding.value),
                      function.parameters.filter({ $0.bindingID == binding }).count == 1,
                      let formal = function.parameters.first(where: { $0.bindingID == binding }),
                      formal.abiLocation == .gpr(index: binding.value, carrierWidth: 64) else { throw Failure.unsupported("selected signed multiply unbound/narrow base") }
                name = "x\(binding.value)"
            default: throw Failure.unsupported("selected signed multiply base/return shape")
            }
            guard let n = A64MachineState.gprIndex(name), n < 31, name == "x\(n)", required == nil || name == required else { throw Failure.unsupported("selected signed multiply base/return") }
        }
        for (position, i) in list.enumerated() {
            guard i.neonFullWidthShift == nil, i.neonScalarVariableShift == nil, i.neonWiderChannelMemory == nil, i.neonMultiChannelLane == nil, i.neonWiderMultiChannelLane == nil, i.neonWiderMultiChannelReplicate == nil, i.neonScalarShiftCompilerComposition == nil, i.neonScalarMaskSelection == nil, i.neonScalarIntegerComparison == nil, i.neonMultiChannelReplicate == nil, i.neonFourChannelMemory == nil, i.neonMixedByteDotProduct == nil, i.neonByteMatrixAccumulate == nil, i.neonIndexedMixedByteDotProduct == nil, i.neonSelectedWideningAccumulate == nil, i.neonIndexedByteDotProduct == nil, i.neonBytePolynomialMultiply == nil, i.neonSelectedUnsignedMultiply == nil, i.neonByteDotProduct == nil, i.neonThreeChannelMemory == nil, i.neonRoundedShift == nil, i.neonSignedLongMultiply == nil, i.neonWideningAddSubtract == nil, i.neonContiguousGroup == nil, i.neonShiftNarrow == nil, i.neonPredicate == nil,
                  i.neonWideningPairwise == nil, i.neonMagnitudeClamp == nil, i.neonPairwise == nil,
                  i.neonLaneMemory == nil, i.neonBroadcastMemory == nil, i.neonBitCount == nil,
                  i.neonOrderConversion == nil, i.neonInterleavedMemory == nil, i.neonIndexedMemory == nil,
                  i.neonBufferSequence == nil, i.neonBitView == nil, i.neonReduction == nil, i.neonPacking == nil,
                  i.neonImmediate == nil, i.neonMultiply == nil, i.neonShiftInsert == nil, i.neonLogical == nil,
                  i.neonExtract == nil, i.neonPermutation == nil, i.neonModular == nil, i.neonComparison == nil,
                  i.neonTableLookup == nil, i.scalarFP == nil,
                  i.id == .init(sourceAddress: i.source.address, effectOrdinal: 0) else { throw Failure.unsupported("selected signed multiply competing metadata") }
            guard i.source.address.isMultiple(of: 4) else { throw Failure.unsupported("selected signed multiply PC alignment") }
            if let pc = previousPC { guard pc <= UInt64.max-4, i.source.address == pc+4 else { throw Failure.unsupported("selected signed multiply PC order") } }
            previousPC = i.source.address
            if let descriptor = i.neonSelectedSignedMultiply {
                guard i.neonScalarVariableShift == nil, i.neonWiderChannelMemory == nil, i.neonMultiChannelLane == nil, i.neonWiderMultiChannelLane == nil, i.neonWiderMultiChannelReplicate == nil, i.neonScalarShiftCompilerComposition == nil, i.neonScalarMaskSelection == nil, i.neonScalarIntegerComparison == nil, i.neonMultiChannelReplicate == nil else { throw Failure.unsupported("new82 foreign metadata exclusion") }
                guard i.neonBufferMemory == nil, i.memoryAccess == nil, i.returnTarget == nil,
                      case let .intrinsic(destination?, _, arguments) = i.operation, arguments.count == 2 else { throw Failure.unsupported("selected signed multiply typed shape") }
                try vector(arguments[0], write: false); try vector(arguments[1], write: false)
                // The physical H coefficient register has only four encoding bits.
                guard case let .register(coefficientName, _) = arguments[1],
                      let coefficientIndex = A64MachineState.vectorIndex(coefficientName),
                      descriptor.narrowBits != 16 || coefficientIndex < 16 else { throw Failure.unsupported("selected signed multiply H coefficient register") }
                try vector(destination, write: true)
            } else if let memory = i.neonBufferMemory {
                guard memory.sequence == sequence, i.memoryAccess == .init(byteWidth: 16), i.returnTarget == nil else { throw Failure.unsupported("selected signed multiply Q access/order") }
                try base(memory.base)
                switch (memory.effect, i.operation) {
                case let (.load, .load(destination, address)) where address == memory.address: try vector(destination, write: true)
                case let (.store, .store(source, address)) where address == memory.address: try vector(source, write: false)
                default: throw Failure.unsupported("selected signed multiply Q shape")
                }
                sequence += 1; if memory.effect == .load { loads += 1 } else { stores += 1 }
            } else {
                guard i.memoryAccess == nil else { throw Failure.unsupported("selected signed multiply untyped memory") }
                switch i.operation {
                case .returnValue(nil) where position == list.count-1:
                    guard let target = i.returnTarget else { throw Failure.unsupported("selected signed multiply missing return") }
                    try base(target, required: "x30")
                case .intrinsic(nil, "nop", let arguments) where arguments.isEmpty && i.returnTarget == nil: break
                default: throw Failure.unsupported("selected signed multiply untyped effect")
                }
            }
        }
        guard sequence == 0 || (loads > 0 && stores > 0) else { throw Failure.unsupported("selected signed multiply incomplete buffer") }
    }
    mutating func executeNEONSelectedSignedMultiply(_ descriptor: MacIRNEONSelectedSignedMultiply, operation: MacIROperation) throws {
        guard case let .intrinsic(destination?, _, arguments) = operation, arguments.count == 2 else { throw Failure.unsupported("selected signed multiply intrinsic") }
        // Capture BOTH full128 operands before the destination can be overwritten.
        let first = try readNEONRegister(arguments[0]), coefficientVector = try readNEONRegister(arguments[1])
        guard first.width == 128, coefficientVector.width == 128 else { throw Failure.unsupported("selected signed multiply full128 captures") }
        let bits = descriptor.narrowBits, outputBits = descriptor.outputLaneBits
        let mask = (UInt64(1) << bits)-1
        let outputMask = outputBits == 64 ? UInt64.max : (UInt64(1) << outputBits)-1
        func signedLane(_ value: Scalar, offset: Int) -> UInt64 {
            let lane = ((offset < 64 ? value.bits : value.high) >> (offset % 64)) & mask
            return lane & (UInt64(1) << (bits-1)) != 0 ? lane | (outputMask ^ mask) : lane
        }
        // Select once from the COMPLETE coefficient vector, independently of Q.
        let coefficient = signedLane(coefficientVector, offset: descriptor.coefficient.index * bits)
        var low: UInt64 = 0, high: UInt64 = 0
        for index in 0..<descriptor.laneCount {
            let sourceOffset = index * bits + (descriptor.firstSource.highHalf ? 64 : 0)
            let source = signedLane(first, offset: sourceOffset)
            // Unsigned-host wrapping product of sign-extended bit patterns is the
            // exact doubled-width signed product, including 32-bit minimum cases.
            let result = (source &* coefficient) & outputMask
            let offset = index * outputBits
            if offset < 64 { low |= result << offset } else { high |= result << (offset-64) }
        }
        try writeNEONRegister(destination, .init(bits: low, width: 128, kind: .unsigned, high: high))
    }
}

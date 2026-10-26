import Foundation
#if canImport(MacScope)
@testable import MacScope
#endif

extension MacIRConcreteEvaluator {
    /// The sole permission to skip incompatible standalone58/52 validation is a
    /// successful exhaustive certificate for this exact list, before any payload.
    /// No source text/intrinsic display name is used to infer a typed operation.
    func validateNEONProductPairwiseBuffer(_ list: [MacIRInstruction]) throws -> MacIRNEONProductPairwiseBuffer? {
        guard !list.contains(where: { $0.neonLaneCoefficientProduct != nil || $0.neonReplicatedIndexedProduct != nil }) else { throw Failure.unsupported("replicated product marker in standalone family") }
        guard list.contains(where: { $0.neonSignedLongMultiply != nil }),
              list.contains(where: { $0.neonWideningPairwise != nil }) else { return nil }
        guard (2...64).contains(list.count), list.last?.operation == .returnValue(nil),
              Set(list.map(\.id)).count == list.count,
              !function.parameters.contains(where: {
                  switch $0.abiLocation { case .simd, .entryStack: return true; default: return false }
              }) else { throw Failure.unsupported("product pairwise bound/identity/formals/terminal") }
        var versions: [String: Int] = [:], qSequence = 0
        var entries: [MacIRNEONProductPairwiseBuffer.Entry] = []
        func vector(_ value: MacIRValue, write: Bool) throws -> String {
            guard case let .register(name, version) = value,
                  let n = A64MachineState.vectorIndex(name), name == "v\(n)",
                  version == versions[name, default: 0] + (write ? 1 : 0) else {
                throw Failure.unsupported("product pairwise current physical128 snapshot")
            }
            if write { versions[name] = version }; return name
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
                      }) else { throw Failure.unsupported("product pairwise bypassed physical GPR formal") }
                name = n
            case let .argument(binding):
                guard binding.kind == .gpr, (0..<8).contains(binding.value),
                      function.parameters.filter({ $0.bindingID == binding }).count == 1,
                      function.parameters.first(where: { $0.bindingID == binding })?.abiLocation == .gpr(index: binding.value, carrierWidth: 64) else {
                    throw Failure.unsupported("product pairwise unbound/narrow base")
                }
                name = "x\(binding.value)"
            default: throw Failure.unsupported("product pairwise base/return shape")
            }
            guard let n = A64MachineState.gprIndex(name), n < 31, name == "x\(n)",
                  required == nil || name == required else { throw Failure.unsupported("product pairwise base/return register") }
        }
        for (ordinal, i) in list.enumerated() {
            // Inspect every effect, including an attempted foreign frame interior.
            guard i.neonFullWidthShift == nil, i.neonScalarVariableShift == nil, i.neonWiderChannelMemory == nil, i.neonMultiChannelLane == nil, i.neonWiderMultiChannelLane == nil, i.neonWiderMultiChannelReplicate == nil, i.neonScalarShiftCompilerComposition == nil, i.neonScalarMaskSelection == nil, i.neonScalarIntegerComparison == nil, i.neonMultiChannelReplicate == nil, i.neonFourChannelMemory == nil, i.neonMixedByteDotProduct == nil, i.neonByteMatrixAccumulate == nil, i.neonIndexedMixedByteDotProduct == nil, i.neonSelectedWideningAccumulate == nil, i.neonIndexedByteDotProduct == nil, i.neonRoundedShift == nil, i.neonThreeChannelMemory == nil, i.neonWideningAddSubtract == nil, i.neonContiguousGroup == nil, i.neonShiftNarrow == nil,
                  i.neonPredicate == nil, i.neonMagnitudeClamp == nil, i.neonPairwise == nil,
                  i.neonLaneMemory == nil, i.neonBroadcastMemory == nil, i.neonBitCount == nil,
                  i.neonOrderConversion == nil, i.neonInterleavedMemory == nil, i.neonIndexedMemory == nil,
                  i.neonBufferSequence == nil, i.neonBitView == nil, i.neonReduction == nil,
                  i.neonPacking == nil, i.neonImmediate == nil, i.neonMultiply == nil,
                  i.neonShiftInsert == nil, i.neonLogical == nil, i.neonExtract == nil,
                  i.neonPermutation == nil, i.neonModular == nil, i.neonComparison == nil,
                  i.neonTableLookup == nil, i.scalarFP == nil,
                  i.id == .init(sourceAddress: i.source.address, effectOrdinal: 0) else {
                throw Failure.unsupported("product pairwise competing metadata/effect identity")
            }
            let family: MacIRNEONProductPairwiseBuffer.Family
            var transferOrdinal: Int?
            if let d = i.neonSignedLongMultiply {
                guard [8, 16].contains(d.narrowBits), i.neonWideningPairwise == nil,
                      i.neonBufferMemory == nil, i.memoryAccess == nil, i.returnTarget == nil,
                      case let .intrinsic(destination?, _, arguments) = i.operation, arguments.count == 2 else {
                    throw Failure.unsupported("product pairwise signed product typed shape/width")
                }
                _ = try vector(arguments[0], write: false)
                _ = try vector(arguments[1], write: false)
                _ = try vector(destination, write: true); family = .product
            } else if let d = i.neonWideningPairwise {
                guard d.isSigned, [2, 4].contains(d.sourceElementBytes),
                      i.neonBufferMemory == nil, i.memoryAccess == nil, i.returnTarget == nil,
                      case let .intrinsic(destination?, _, arguments) = i.operation, arguments.count == d.arity else {
                    throw Failure.unsupported("product pairwise signed pair typed shape/width")
                }
                _ = try vector(arguments[0], write: false)
                if d.accumulates {
                    let oldName = try vector(arguments[1], write: false)
                    guard case let .register(name, _) = destination, name == oldName else {
                        throw Failure.unsupported("product pairwise actual old accumulator")
                    }
                }
                _ = try vector(destination, write: true); family = .signedPairwise
            } else if let memory = i.neonBufferMemory {
                guard memory.sequence == qSequence, i.memoryAccess == .init(byteWidth: 16), i.returnTarget == nil else {
                    throw Failure.unsupported("product pairwise Q access/transfer ordinal")
                }
                try base(memory.base)
                switch (memory.effect, i.operation) {
                case let (.load, .load(destination, address)) where address == memory.address:
                    _ = try vector(destination, write: true); family = .loadQ
                case let (.store, .store(source, address)) where address == memory.address:
                    _ = try vector(source, write: false); family = .storeQ
                default: throw Failure.unsupported("product pairwise Q shape/address")
                }
                transferOrdinal = qSequence; qSequence += 1
            } else {
                guard i.memoryAccess == nil else { throw Failure.unsupported("product pairwise untyped memory") }
                switch i.operation {
                case .returnValue(nil) where ordinal == list.count - 1:
                    guard let target = i.returnTarget else { throw Failure.unsupported("product pairwise missing return target") }
                    try base(target, required: "x30"); family = .terminal
                case .intrinsic(nil, "nop", let args) where args.isEmpty && i.returnTarget == nil:
                    family = .nop
                default: throw Failure.unsupported("product pairwise untyped effect")
                }
            }
            entries.append(.init(family: family, rowOrdinal: ordinal, identity: i.id, qTransferOrdinal: transferOrdinal))
        }
        guard let certificate = MacIRNEONProductPairwiseBuffer(entries: entries) else {
            throw Failure.unsupported("product pairwise exhaustive original-row/Q map")
        }
        return certificate
    }
}

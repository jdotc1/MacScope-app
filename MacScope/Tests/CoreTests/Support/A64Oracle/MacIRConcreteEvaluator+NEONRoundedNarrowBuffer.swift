import Foundation
#if canImport(MacScope)
@testable import MacScope
#endif

extension MacIRConcreteEvaluator {
    /// The sole permission to skip incompatible standalone63/54 validation is a
    /// successful exhaustive certificate for this exact list, before any payload.
    /// No source text/intrinsic display name is used to infer a typed operation.
    func validateNEONRoundedNarrowBuffer(_ list: [MacIRInstruction]) throws -> MacIRNEONRoundedNarrowBuffer? {
        guard !list.contains(where: { $0.neonLaneCoefficientProduct != nil || $0.neonReplicatedIndexedProduct != nil }) else { throw Failure.unsupported("replicated product marker in standalone family") }
        guard list.contains(where: { $0.neonRoundedShift != nil }),
              list.contains(where: { $0.neonShiftNarrow != nil }) else { return nil }
        guard (2...64).contains(list.count), list.last?.operation == .returnValue(nil),
              Set(list.map(\.id)).count == list.count,
              !function.parameters.contains(where: {
                  switch $0.abiLocation { case .simd, .entryStack: return true; default: return false }
              }) else { throw Failure.unsupported("rounded narrow bound/identity/formals/terminal") }
        var versions: [String: Int] = [:], qSequence = 0
        var entries: [MacIRNEONRoundedNarrowBuffer.Entry] = []
        var roundedWidths: [MacIRValue: Int] = [:]
        func vector(_ value: MacIRValue, write: Bool) throws -> String {
            guard case let .register(name, version) = value,
                  let n = A64MachineState.vectorIndex(name), name == "v\(n)",
                  version == versions[name, default: 0] + (write ? 1 : 0) else {
                throw Failure.unsupported("rounded narrow current physical128 snapshot")
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
                      }) else { throw Failure.unsupported("rounded narrow bypassed physical GPR formal") }
                name = n
            case let .argument(binding):
                guard binding.kind == .gpr, (0..<8).contains(binding.value),
                      function.parameters.filter({ formal in
                          if case let .gpr(index, _) = formal.abiLocation, index == binding.value { return true }
                          return formal.bindingID == binding
                      }).count == 1,
                      function.parameters.first(where: { $0.bindingID == binding })?.abiLocation == .gpr(index: binding.value, carrierWidth: 64) else {
                    throw Failure.unsupported("rounded narrow unbound/narrow base")
                }
                name = "x\(binding.value)"
            default: throw Failure.unsupported("rounded narrow base/return shape")
            }
            guard let n = A64MachineState.gprIndex(name), n < 31, name == "x\(n)",
                  required == nil || name == required else { throw Failure.unsupported("rounded narrow base/return register") }
        }
        for (ordinal, i) in list.enumerated() {
            // Inspect every effect, including an attempted foreign frame interior.
            guard i.neonFullWidthShift == nil, i.neonScalarVariableShift == nil, i.neonWiderChannelMemory == nil, i.neonMultiChannelLane == nil, i.neonWiderMultiChannelLane == nil, i.neonWiderMultiChannelReplicate == nil, i.neonScalarShiftCompilerComposition == nil, i.neonScalarMaskSelection == nil, i.neonScalarIntegerComparison == nil, i.neonMultiChannelReplicate == nil, i.neonFourChannelMemory == nil, i.neonMixedByteDotProduct == nil, i.neonByteMatrixAccumulate == nil, i.neonIndexedMixedByteDotProduct == nil, i.neonSelectedWideningAccumulate == nil, i.neonSelectedSignedMultiply == nil, i.neonIndexedByteDotProduct == nil, i.neonBytePolynomialMultiply == nil, i.neonSelectedUnsignedMultiply == nil, i.neonByteDotProduct == nil,
                  i.neonThreeChannelMemory == nil, i.neonSignedLongMultiply == nil, i.neonWideningPairwise == nil,
                  i.neonWideningAddSubtract == nil, i.neonContiguousGroup == nil,
                  i.neonPredicate == nil, i.neonMagnitudeClamp == nil, i.neonPairwise == nil,
                  i.neonLaneMemory == nil, i.neonBroadcastMemory == nil, i.neonBitCount == nil,
                  i.neonOrderConversion == nil, i.neonInterleavedMemory == nil, i.neonIndexedMemory == nil,
                  i.neonBufferSequence == nil, i.neonBitView == nil, i.neonReduction == nil,
                  i.neonPacking == nil, i.neonImmediate == nil, i.neonMultiply == nil,
                  i.neonShiftInsert == nil, i.neonLogical == nil, i.neonExtract == nil,
                  i.neonPermutation == nil, i.neonModular == nil, i.neonComparison == nil,
                  i.neonTableLookup == nil, i.scalarFP == nil,
                  i.id == .init(sourceAddress: i.source.address, effectOrdinal: 0) else {
                throw Failure.unsupported("rounded narrow competing metadata/effect identity")
            }
            let family: MacIRNEONRoundedNarrowBuffer.Family
            var transferOrdinal: Int?
            if let d = i.neonRoundedShift {
                guard [16, 32, 64].contains(d.elementBits), i.neonShiftNarrow == nil,
                      i.neonBufferMemory == nil, i.memoryAccess == nil, i.returnTarget == nil,
                      case let .intrinsic(destination?, _, arguments) = i.operation, arguments.count == 1 else {
                    throw Failure.unsupported("rounded narrow rounding typed shape/width")
                }
                _ = try vector(arguments[0], write: false)
                _ = try vector(destination, write: true)
                roundedWidths[destination] = d.elementBits; family = .rounded
            } else if let d = i.neonShiftNarrow {
                guard i.neonScalarVariableShift == nil, i.neonWiderChannelMemory == nil, i.neonMultiChannelLane == nil, i.neonWiderMultiChannelLane == nil, i.neonWiderMultiChannelReplicate == nil, i.neonScalarShiftCompilerComposition == nil, i.neonScalarMaskSelection == nil, i.neonScalarIntegerComparison == nil, i.neonMultiChannelReplicate == nil else { throw Failure.unsupported("new82 foreign metadata exclusion") }
                guard i.neonBufferMemory == nil, i.memoryAccess == nil, i.returnTarget == nil,
                      case let .intrinsic(destination?, _, arguments) = i.operation,
                      arguments.count == (d.destinationHighHalf ? 2 : 1),
                      roundedWidths[arguments[0]] == 2 * d.narrowBits else {
                    throw Failure.unsupported("rounded narrow separate matching rounded source")
                }
                _ = try vector(arguments[0], write: false)
                if d.destinationHighHalf {
                    let oldName = try vector(arguments[1], write: false)
                    guard case let .register(name, version) = destination, name == oldName, version > 0,
                          arguments[1] == .register(name: name, version: version - 1) else {
                        throw Failure.unsupported("rounded narrow actual OLD low destination")
                    }
                }
                _ = try vector(destination, write: true); family = .narrow
            } else if let memory = i.neonBufferMemory {
                guard memory.sequence == qSequence, i.memoryAccess == .init(byteWidth: 16), i.returnTarget == nil else {
                    throw Failure.unsupported("rounded narrow Q access/transfer ordinal")
                }
                try base(memory.base)
                switch (memory.effect, i.operation) {
                case let (.load, .load(destination, address)) where address == memory.address:
                    _ = try vector(destination, write: true); family = .loadQ
                case let (.store, .store(source, address)) where address == memory.address:
                    _ = try vector(source, write: false); family = .storeQ
                default: throw Failure.unsupported("rounded narrow Q shape/address")
                }
                transferOrdinal = qSequence; qSequence += 1
            } else {
                guard i.memoryAccess == nil else { throw Failure.unsupported("rounded narrow untyped memory") }
                switch i.operation {
                case .returnValue(nil) where ordinal == list.count - 1:
                    guard let target = i.returnTarget else { throw Failure.unsupported("rounded narrow missing return target") }
                    try base(target, required: "x30"); family = .terminal
                case .intrinsic(nil, "nop", let args) where args.isEmpty && i.returnTarget == nil:
                    family = .nop
                default: throw Failure.unsupported("rounded narrow untyped effect")
                }
            }
            entries.append(.init(family: family, rowOrdinal: ordinal, identity: i.id, qTransferOrdinal: transferOrdinal))
        }
        guard let certificate = MacIRNEONRoundedNarrowBuffer(entries: entries) else {
            throw Failure.unsupported("rounded narrow exhaustive original-row/Q map")
        }
        return certificate
    }
}

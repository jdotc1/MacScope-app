import Foundation
#if canImport(MacScope)
@testable import MacScope
#endif

extension MacIRConcreteEvaluator {
    /// Run before all composition certificates and payload. Examine every
    /// interior, so a foreign composition cannot hide a new typed operation.
    func validateNEONScalarVariableShift(_ list: [MacIRInstruction]) throws -> MacIRNEONScalarVariableShiftCertificate? {
        guard !list.contains(where: { $0.neonLaneCoefficientProduct != nil || $0.neonReplicatedIndexedProduct != nil }) else { throw Failure.unsupported("replicated product marker in standalone family") }
        guard list.contains(where: { $0.neonScalarVariableShift != nil }) else { return nil }
        guard (2...64).contains(list.count), list.last?.operation == .returnValue(nil),
              Set(list.map(\.id)).count == list.count,
              !function.parameters.contains(where: {
                  switch $0.abiLocation { case .simd, .entryStack: return true; default: return false }
              }) else { throw Failure.unsupported("scalar variable shift whole-list bound/identity/formals") }
        var physicalFormals: Set<Int> = []
        for formal in function.parameters {
            guard case let .gpr(index, width) = formal.abiLocation, (0..<8).contains(index), width == 64,
                  formal.bindingID?.kind == .gpr, formal.bindingID?.value == index, physicalFormals.insert(index).inserted else { throw Failure.unsupported("scalar variable shift unique exact64 physical formals") }
        }
        var versions: [String: Int] = [:], sequence = 0, loads = 0, stores = 0, previousPC: UInt64?
        var shifted: Set<MacIRValue> = [], shifts = 0, observed = 0
        func vector(_ value: MacIRValue, write: Bool, required: Int? = nil) throws {
            guard case let .register(name, version) = value, let n = A64MachineState.vectorIndex(name), name == "v\(n)", required == nil || n == required,
                  version == versions[name, default: 0] + (write ? 1 : 0) else { throw Failure.unsupported("scalar variable shift current physical128 snapshot") }
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
                      }) else { throw Failure.unsupported("scalar variable shift bypassed physical GPR formal") }
                name = n
            case let .argument(binding):
                guard binding.kind == .gpr, (0..<8).contains(binding.value),
                      function.parameters.filter({ formal in
                          if case let .gpr(index, _) = formal.abiLocation, index == binding.value { return true }
                          return formal.bindingID == binding
                      }).count == 1,
                      let formal = function.parameters.first(where: { $0.bindingID == binding }),
                      formal.abiLocation == .gpr(index: binding.value, carrierWidth: 64) else { throw Failure.unsupported("scalar variable shift unbound/narrow base") }
                name = "x\(binding.value)"
            default: throw Failure.unsupported("scalar variable shift base/return shape")
            }
            guard let n = A64MachineState.gprIndex(name), n < 31, name == "x\(n)", required == nil || name == required else { throw Failure.unsupported("scalar variable shift base/return") }
        }
        for (position, i) in list.enumerated() {
            guard i.neonWiderChannelMemory == nil, i.neonMultiChannelLane == nil, i.scalarFP == nil,
                  i.neonPermutation == nil,
                  i.neonLogical == nil,
                  i.neonExtract == nil,
                  i.neonTableLookup == nil,
                  i.neonModular == nil,
                  i.neonComparison == nil,
                  i.neonBitView == nil,
                  i.neonBufferSequence == nil,
                  i.neonShiftInsert == nil,
                  i.neonMultiply == nil,
                  i.neonImmediate == nil,
                  i.neonReduction == nil,
                  i.neonPacking == nil,
                  i.neonLaneMemory == nil,
                  i.neonWideningPairwise == nil,
                  i.neonPredicate == nil,
                  i.neonShiftNarrow == nil,
                  i.neonContiguousGroup == nil,
                  i.neonMagnitudeClamp == nil,
                  i.neonPairwise == nil,
                  i.neonBroadcastMemory == nil,
                  i.neonBitCount == nil,
                  i.neonOrderConversion == nil,
                  i.neonInterleavedMemory == nil,
                  i.neonIndexedMemory == nil,
                  i.neonWideningAddSubtract == nil,
                  i.neonSignedLongMultiply == nil,
                  i.neonWiderMultiChannelLane == nil, i.neonWiderMultiChannelReplicate == nil, i.neonScalarShiftCompilerComposition == nil, i.neonScalarMaskSelection == nil, i.neonScalarIntegerComparison == nil, i.neonMultiChannelReplicate == nil,
                  i.neonFourChannelMemory == nil,
                  i.neonThreeChannelMemory == nil,
                  i.neonByteMatrixAccumulate == nil,
                  i.neonIndexedMixedByteDotProduct == nil,
                  i.neonMixedByteDotProduct == nil,
                  i.neonFullWidthShift == nil,
                  i.neonRoundedShift == nil,
                  i.neonSelectedSignedMultiply == nil,
                  i.neonSelectedWideningAccumulate == nil,
                  i.neonIndexedByteDotProduct == nil,
                  i.neonByteDotProduct == nil,
                  i.neonSelectedUnsignedMultiply == nil,
                  i.neonBytePolynomialMultiply == nil,
                  i.id == .init(sourceAddress: i.source.address, effectOrdinal: 0) else { throw Failure.unsupported("scalar variable shift competing metadata/identity") }
            guard i.source.address.isMultiple(of: 4) else { throw Failure.unsupported("scalar variable shift PC alignment") }
            if let pc = previousPC { guard pc <= UInt64.max-4, i.source.address == pc+4 else { throw Failure.unsupported("scalar variable shift PC order") } }
            previousPC = i.source.address
            if let descriptor = i.neonScalarVariableShift {
                guard i.neonWiderMultiChannelLane == nil, i.neonWiderMultiChannelReplicate == nil, i.neonScalarShiftCompilerComposition == nil, i.neonScalarMaskSelection == nil, i.neonScalarIntegerComparison == nil, i.neonMultiChannelReplicate == nil else { throw Failure.unsupported("new82 foreign metadata exclusion") }
                guard i.neonBufferMemory == nil, i.memoryAccess == nil, i.returnTarget == nil,
                      case let .intrinsic(destination?, _, arguments) = i.operation, arguments.count == 2 else { throw Failure.unsupported("scalar variable shift typed shape") }
                try vector(arguments[0], write: false, required: descriptor.source)
                try vector(arguments[1], write: false, required: descriptor.count)
                try vector(destination, write: true, required: descriptor.destination)
                shifted.insert(destination); shifts += 1
            } else if let memory = i.neonBufferMemory {
                guard memory.sequence == sequence, i.memoryAccess == .init(byteWidth: 16), i.returnTarget == nil else { throw Failure.unsupported("scalar variable shift Q access/order") }
                try base(memory.base)
                switch (memory.effect, i.operation) {
                case let (.load, .load(destination, address)) where address == memory.address: try vector(destination, write: true)
                case let (.store, .store(source, address)) where address == memory.address:
                    try vector(source, write: false)
                    if shifted.contains(source) { observed += 1 }
                default: throw Failure.unsupported("scalar variable shift Q shape")
                }
                sequence += 1; if memory.effect == .load { loads += 1 } else { stores += 1 }
            } else {
                guard i.memoryAccess == nil else { throw Failure.unsupported("scalar variable shift untyped memory") }
                switch i.operation {
                case .returnValue(nil) where position == list.count-1:
                    guard i.returnTarget == .register(name: "x30", version: 0) else { throw Failure.unsupported("scalar variable shift exact physical return") }
                case .intrinsic(nil, "nop", let arguments) where arguments.isEmpty && i.returnTarget == nil: break
                default: throw Failure.unsupported("scalar variable shift untyped effect")
                }
            }
        }
        guard shifts > 0, loads > 0, stores > 0, observed > 0 else { throw Failure.unsupported("scalar variable shift incomplete buffer") }
        return .init(rowCount: list.count, shiftCount: shifts, qMemoryCount: sequence, observedShiftStores: observed)
    }
    mutating func executeNEONScalarVariableShift(_ descriptor: MacIRNEONScalarVariableShift, operation: MacIROperation) throws {
        guard case let .intrinsic(destination?, _, arguments) = operation, arguments.count == 2 else { throw Failure.unsupported("scalar variable shift intrinsic") }
        guard case let .register(d, _) = destination, d == "v\(descriptor.destination)",
              case let .register(n, _) = arguments[0], n == "v\(descriptor.source)",
              case let .register(m, _) = arguments[1], m == "v\(descriptor.count)" else { throw Failure.unsupported("scalar variable shift physical roles") }
        // Both complete physical sources precede any write, even all-three aliases.
        let source = try readNEONRegister(arguments[0])
        let count = try readNEONRegister(arguments[1])
        guard source.width == 128, count.width == 128 else { throw Failure.unsupported("scalar variable shift physical128 capture") }
        let result = descriptor.evaluate(value: source.bits, countBits: count.bits)
        try writeNEONRegister(destination, .init(bits: result.low, width: 128, kind: .unsigned, high: result.high))
    }
}

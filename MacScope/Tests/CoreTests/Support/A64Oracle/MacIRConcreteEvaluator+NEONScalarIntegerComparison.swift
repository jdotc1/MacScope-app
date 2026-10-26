import Foundation
#if canImport(MacScope)
@testable import MacScope
#endif

extension MacIRConcreteEvaluator {
    /// Run before all composition certificates and payload. Examine every
    /// interior, so a foreign composition cannot hide a new typed operation.
    func validateNEONScalarIntegerComparison(_ list: [MacIRInstruction]) throws {
        guard list.contains(where: { $0.neonScalarIntegerComparison != nil }) else { return }
        guard !list.contains(where: { $0.neonScalarMaskSelection != nil }) else { throw Failure.unsupported("scalar mask selection requires complete composition certificate") }
        guard (2...64).contains(list.count), list.last?.operation == .returnValue(nil),
              Set(list.map(\.id)).count == list.count,
              !function.parameters.contains(where: {
                  switch $0.abiLocation { case .simd, .entryStack: return true; default: return false }
              }) else { throw Failure.unsupported("scalar integer comparison whole-list bound/identity/formals") }
        var physicalFormals: Set<Int> = []
        for formal in function.parameters {
            guard case let .gpr(index, width) = formal.abiLocation, (0..<8).contains(index), width == 64,
                  formal.bindingID == .gpr(index), physicalFormals.insert(index).inserted else { throw Failure.unsupported("scalar integer comparison unique exact64 physical formals") }
        }
        var versions: [String: Int] = [:], sequence = 0, loads = 0, stores = 0, previousPC: UInt64?
        var values = Set<MacIRValue>(), masks = Set<MacIRValue>(), consumed = Set<MacIRValue>()
        func vector(_ value: MacIRValue, write: Bool) throws {
            guard case let .register(name, version) = value, let n = A64MachineState.vectorIndex(name), name == "v\(n)",
                  version == versions[name, default: 0] + (write ? 1 : 0) else { throw Failure.unsupported("scalar integer comparison current physical128 snapshot") }
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
                      }) else { throw Failure.unsupported("scalar integer comparison bypassed physical GPR formal") }
                name = n
            case let .argument(binding):
                guard binding.kind == .gpr, (0..<8).contains(binding.value),
                      function.parameters.filter({ formal in
                          if case let .gpr(index, _) = formal.abiLocation, index == binding.value { return true }
                          return formal.bindingID == binding
                      }).count == 1,
                      let formal = function.parameters.first(where: { $0.bindingID == binding }),
                      formal.abiLocation == .gpr(index: binding.value, carrierWidth: 64) else { throw Failure.unsupported("scalar integer comparison unbound/narrow base") }
                name = "x\(binding.value)"
            default: throw Failure.unsupported("scalar integer comparison base/return shape")
            }
            guard let n = A64MachineState.gprIndex(name), n < 31, name == "x\(n)", required == nil || name == required else { throw Failure.unsupported("scalar integer comparison base/return") }
        }
        for (position, i) in list.enumerated() {
            guard i.scalarFP == nil, i.neonPermutation == nil, i.neonLogical == nil, i.neonExtract == nil, i.neonTableLookup == nil, i.neonModular == nil, i.neonComparison == nil, i.neonBitView == nil, i.neonBufferSequence == nil, i.neonShiftInsert == nil, i.neonMultiply == nil, i.neonImmediate == nil, i.neonReduction == nil, i.neonPacking == nil, i.neonLaneMemory == nil, i.neonWideningPairwise == nil, i.neonPredicate == nil, i.neonShiftNarrow == nil, i.neonContiguousGroup == nil, i.neonMagnitudeClamp == nil, i.neonPairwise == nil, i.neonBroadcastMemory == nil, i.neonBitCount == nil, i.neonOrderConversion == nil, i.neonInterleavedMemory == nil, i.neonIndexedMemory == nil, i.neonWideningAddSubtract == nil, i.neonSignedLongMultiply == nil, i.neonWiderChannelMemory == nil, i.neonMultiChannelLane == nil, i.neonScalarShiftCompilerComposition == nil, i.neonLaneCoefficientProduct == nil, i.neonReplicatedIndexedProduct == nil, i.neonScalarVariableShift == nil, i.neonWiderMultiChannelReplicate == nil, i.neonWiderMultiChannelLane == nil, i.neonMultiChannelReplicate == nil, i.neonFourChannelMemory == nil, i.neonThreeChannelMemory == nil, i.neonByteMatrixAccumulate == nil, i.neonIndexedMixedByteDotProduct == nil, i.neonMixedByteDotProduct == nil, i.neonFullWidthShift == nil, i.neonRoundedShift == nil, i.neonSelectedSignedMultiply == nil, i.neonSelectedWideningAccumulate == nil, i.neonIndexedByteDotProduct == nil, i.neonByteDotProduct == nil, i.neonSelectedUnsignedMultiply == nil, i.neonBytePolynomialMultiply == nil,
                  i.id == .init(sourceAddress: i.source.address, effectOrdinal: 0) else { throw Failure.unsupported("scalar comparison foreign metadata/identity") }
            guard i.source.address.isMultiple(of: 4) else { throw Failure.unsupported("scalar integer comparison PC alignment") }
            if let pc = previousPC { guard pc <= UInt64.max-4, i.source.address == pc+4 else { throw Failure.unsupported("scalar integer comparison PC order") } }
            previousPC = i.source.address
            if let d = i.neonScalarIntegerComparison {
                guard i.neonBufferMemory == nil, i.memoryAccess == nil, i.returnTarget == nil,
                      case let .intrinsic(destination?, _, arguments) = i.operation, arguments.count == 2,
                      MacIRNEONScalarIntegerComparison(encodedWord: d.encodedWord) == d,
                      case let .register(dn, _) = destination, dn == "v\(d.destination)",
                      case let .register(an, _) = arguments[0], an == "v\(d.lhs)",
                      case let .register(bn, _) = arguments[1], bn == "v\(d.rhs)",
                      values.contains(arguments[0]), values.contains(arguments[1]) else { throw Failure.unsupported("scalar comparison typed/raw operand provenance") }
                try vector(arguments[0], write: false)
                try vector(arguments[1], write: false)
                try vector(destination, write: true)
                consumed.formUnion(arguments); values.insert(destination); masks.insert(destination)
            } else if let memory = i.neonBufferMemory {
                guard memory.sequence == sequence, i.memoryAccess == .init(byteWidth: 16), i.returnTarget == nil else { throw Failure.unsupported("scalar integer comparison Q access/order") }
                try base(memory.base)
                switch (memory.effect, i.operation) {
                case let (.load, .load(destination, address)) where address == memory.address:
                    try vector(destination, write: true); values.insert(destination)
                case let (.store, .store(source, address)) where address == memory.address:
                    guard masks.contains(source) else { throw Failure.unsupported("scalar comparison store must consume latest mask") }
                    try vector(source, write: false); consumed.insert(source)
                default: throw Failure.unsupported("scalar integer comparison Q shape")
                }
                sequence += 1; if memory.effect == .load { loads += 1 } else { stores += 1 }
            } else {
                guard i.memoryAccess == nil else { throw Failure.unsupported("scalar integer comparison untyped memory") }
                switch i.operation {
                case .returnValue(nil) where position == list.count-1:
                    guard let target = i.returnTarget, target == .register(name: "x30", version: 0) else { throw Failure.unsupported("scalar integer comparison missing return") }
                    try base(target, required: "x30")
                case .intrinsic(nil, "nop", let arguments) where arguments.isEmpty && i.returnTarget == nil: break
                default: throw Failure.unsupported("scalar integer comparison untyped effect")
                }
            }
        }
        guard loads > 0, stores > 0, !masks.isEmpty, masks.isSubset(of: consumed) else { throw Failure.unsupported("scalar integer comparison incomplete buffer") }
    }
    mutating func executeNEONScalarIntegerComparison(_ descriptor: MacIRNEONScalarIntegerComparison, operation: MacIROperation) throws {
        guard case let .intrinsic(destination?, _, arguments) = operation, arguments.count == 2 else { throw Failure.unsupported("scalar comparison intrinsic") }
        // Full128 snapshots happen before any destination write, on all aliases.
        let a = try readNEONRegister(arguments[0]), b = try readNEONRegister(arguments[1])
        guard a.width == 128, b.width == 128 else { throw Failure.unsupported("scalar comparison full128 sources") }
        let output = descriptor.evaluate(a.bits, b.bits)
        try writeNEONRegister(destination, .init(bits: output.low, width: 128, kind: .unsigned, high: output.high))
    }
}

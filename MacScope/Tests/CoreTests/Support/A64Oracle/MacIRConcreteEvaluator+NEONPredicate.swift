import Foundation
#if canImport(MacScope)
@testable import MacScope
#endif

extension MacIRConcreteEvaluator {
    /// Inspect the entire list, including every foreign composite interior, before
    /// dispatch. This route does not widen51's composition certificate or any family.
    func validateNEONPredicate(_ list: [MacIRInstruction]) throws {
        guard !list.contains(where: { $0.neonLaneCoefficientProduct != nil || $0.neonReplicatedIndexedProduct != nil }) else { throw Failure.unsupported("replicated product marker in standalone family") }
        guard list.contains(where: { $0.neonPredicate != nil }) else { return }
        guard (2...64).contains(list.count), list.last?.operation == .returnValue(nil),
              Set(list.map(\.id)).count == list.count,
              !function.parameters.contains(where: {
                  switch $0.abiLocation { case .simd, .entryStack: return true; default: return false }
              }) else { throw Failure.unsupported("predicate whole-list bound/identity/formals") }
        var versions: [String: Int] = [:], sequence = 0, loads = 0, stores = 0, previousPC: UInt64?
        func vector(_ value: MacIRValue, write: Bool) throws -> String {
            guard case let .register(name, version) = value, let n = A64MachineState.vectorIndex(name), name == "v\(n)",
                  version == versions[name, default: 0] + (write ? 1 : 0) else { throw Failure.unsupported("predicate current physical128 snapshot") }
            if write { versions[name] = version }; return name
        }
        func base(_ value: MacIRValue, required: String? = nil) throws {
            let name: String
            switch value {
            case let .register(n, version) where version == 0:
                guard !function.parameters.contains(where: { $0.register == n && $0.bindingID != nil }) else { throw Failure.unsupported("predicate bypassed formal") }
                name = n
            case let .argument(binding):
                guard binding.kind == .gpr, (0..<8).contains(binding.value),
                      function.parameters.filter({ $0.bindingID == binding }).count == 1,
                      let formal = function.parameters.first(where: { $0.bindingID == binding }),
                      formal.abiLocation == .gpr(index: binding.value, carrierWidth: 64) else { throw Failure.unsupported("predicate unbound/narrow base") }
                name = "x\(binding.value)"
            default: throw Failure.unsupported("predicate base/return shape")
            }
            guard let n = A64MachineState.gprIndex(name), n < 31, name == "x\(n)", required == nil || name == required else { throw Failure.unsupported("predicate base/return") }
        }
        for (position, i) in list.enumerated() {
            guard i.neonScalarVariableShift == nil, i.neonWiderChannelMemory == nil, i.neonMultiChannelLane == nil, i.neonWiderMultiChannelLane == nil, i.neonWiderMultiChannelReplicate == nil, i.neonScalarShiftCompilerComposition == nil, i.neonScalarMaskSelection == nil, i.neonScalarIntegerComparison == nil, i.neonMultiChannelReplicate == nil else { throw Failure.unsupported("new82 foreign metadata exclusion") }
            guard i.neonWideningPairwise == nil, i.neonMagnitudeClamp == nil, i.neonPairwise == nil, i.neonLaneMemory == nil, i.neonBroadcastMemory == nil,
                  i.neonBitCount == nil, i.neonOrderConversion == nil, i.neonInterleavedMemory == nil, i.neonIndexedMemory == nil,
                  i.neonBufferSequence == nil, i.neonBitView == nil, i.neonReduction == nil, i.neonPacking == nil,
                  i.neonImmediate == nil, i.neonMultiply == nil, i.neonShiftInsert == nil,
                  i.neonExtract == nil, i.neonPermutation == nil, i.neonModular == nil, i.neonComparison == nil,
                  i.neonTableLookup == nil, i.scalarFP == nil else { throw Failure.unsupported("predicate competing metadata") }
            guard i.source.address.isMultiple(of: 4) else { throw Failure.unsupported("predicate PC alignment") }
            if let pc = previousPC { guard pc <= UInt64.max-4, i.source.address == pc+4 else { throw Failure.unsupported("predicate PC order") } }
            previousPC = i.source.address
            if let descriptor = i.neonPredicate {
                guard i.neonScalarVariableShift == nil, i.neonWiderChannelMemory == nil, i.neonMultiChannelLane == nil, i.neonWiderMultiChannelLane == nil, i.neonWiderMultiChannelReplicate == nil, i.neonScalarShiftCompilerComposition == nil, i.neonScalarMaskSelection == nil, i.neonScalarIntegerComparison == nil, i.neonMultiChannelReplicate == nil else { throw Failure.unsupported("new82 foreign metadata exclusion") }
                guard i.neonLogical == nil, i.neonBufferMemory == nil, i.memoryAccess == nil, i.returnTarget == nil,
                      case let .intrinsic(destination?, _, arguments) = i.operation, arguments.count == descriptor.arity else { throw Failure.unsupported("predicate typed shape") }
                for argument in arguments { _ = try vector(argument, write: false) }
                _ = try vector(destination, write: true)
            } else if let logical = i.neonLogical {
                guard i.neonScalarVariableShift == nil, i.neonWiderChannelMemory == nil, i.neonMultiChannelLane == nil, i.neonWiderMultiChannelLane == nil, i.neonWiderMultiChannelReplicate == nil, i.neonScalarShiftCompilerComposition == nil, i.neonScalarMaskSelection == nil, i.neonScalarIntegerComparison == nil, i.neonMultiChannelReplicate == nil else { throw Failure.unsupported("new82 foreign metadata exclusion") }
                guard i.neonBufferMemory == nil, i.memoryAccess == nil, i.returnTarget == nil,
                      case let .intrinsic(destination?, _, arguments) = i.operation,
                      arguments.count == (logical.readsDestination ? 3 : 2) else { throw Failure.unsupported("predicate logical shape") }
                for argument in arguments { _ = try vector(argument, write: false) }
                if logical.readsDestination {
                    guard case let .register(name, _) = destination, arguments[2] == .register(name: name, version: versions[name, default: 0]) else { throw Failure.unsupported("predicate logical old destination role") }
                }
                _ = try vector(destination, write: true)
            } else if let memory = i.neonBufferMemory {
                guard memory.sequence == sequence, i.memoryAccess == .init(byteWidth: 16), i.returnTarget == nil else { throw Failure.unsupported("predicate Q access/order") }
                try base(memory.base)
                switch (memory.effect, i.operation) {
                case let (.load, .load(destination, address)) where address == memory.address: _ = try vector(destination, write: true)
                case let (.store, .store(source, address)) where address == memory.address: _ = try vector(source, write: false)
                default: throw Failure.unsupported("predicate Q shape")
                }
                sequence += 1; if memory.effect == .load { loads += 1 } else { stores += 1 }
            } else {
                guard i.memoryAccess == nil else { throw Failure.unsupported("predicate untyped memory") }
                switch i.operation {
                case .returnValue(nil) where position == list.count-1:
                    guard let target = i.returnTarget else { throw Failure.unsupported("predicate missing return") }
                    try base(target, required: "x30")
                case .intrinsic(nil, "nop", let arguments) where arguments.isEmpty && i.returnTarget == nil: break
                default: throw Failure.unsupported("predicate untyped effect")
                }
            }
        }
        guard sequence == 0 || (loads > 0 && stores > 0) else { throw Failure.unsupported("predicate incomplete buffer") }
    }
    mutating func executeNEONPredicate(_ descriptor: MacIRNEONPredicate, operation: MacIROperation) throws {
        guard case let .intrinsic(destination?, _, arguments) = operation, arguments.count == descriptor.arity else { throw Failure.unsupported("predicate intrinsic") }
        let lhs = try readNEONRegister(arguments[0])
        let rhs = descriptor.comparesZero ? nil : try readNEONRegister(arguments[1])
        guard lhs.width == 128, rhs == nil || rhs?.width == 128 else { throw Failure.unsupported("predicate physical128 sources") }
        let bits = descriptor.elementBytes * 8, mask = bits == 64 ? UInt64.max : (UInt64(1) << bits)-1
        let sign = UInt64(1) << (bits-1)
        var low: UInt64 = 0, high: UInt64 = 0
        for lane in 0..<descriptor.laneCount {
            let shift = lane * bits
            func value(_ source: Scalar) -> UInt64 { ((shift < 64 ? source.bits : source.high) >> (shift % 64)) & mask }
            let a = value(lhs), negative = a & sign != 0, matches: Bool
            switch descriptor.kind {
            case .cmhi: matches = a > value(rhs!)
            case .cmhs: matches = a >= value(rhs!)
            case .cmgt: matches = !negative && a != 0
            case .cmge: matches = !negative
            case .cmeq: matches = a == 0
            case .cmle: matches = negative || a == 0
            case .cmlt: matches = negative
            }
            let result = matches ? mask : 0
            if shift < 64 { low |= result << shift } else { high |= result << (shift-64) }
        }
        // All-ones/zero lanes only; Q0 defines a complete128 value with high64 zero.
        try writeNEONRegister(destination, .init(bits: low, width: 128, kind: .unsigned, high: high))
    }
}

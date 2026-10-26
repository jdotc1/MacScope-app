import Foundation
#if canImport(MacScope)
@testable import MacScope
#endif

extension MacIRConcreteEvaluator {
    /// A narrow whole-list composition certificate. No payload work or address
    /// resolution occurs here. Existing40/41/43 consumer algorithms stay intact.
    func validateNEONConversionBuffer(_ instructions: [MacIRInstruction]) throws -> Bool {
        guard !instructions.contains(where: { $0.neonLaneCoefficientProduct != nil || $0.neonReplicatedIndexedProduct != nil }) else { throw Failure.unsupported("replicated product marker in standalone family") }
        guard instructions.contains(where: { $0.neonIndexedMemory != nil }),
              instructions.contains(where: { $0.neonPacking != nil || $0.neonOrderConversion != nil }) else { return false }
        guard (4...64).contains(instructions.count) else { throw Failure.unsupported("NEON conversion buffer bound") }
        var ordinal = 0, loads = 0, stores = 0, versions: [String: Int] = [:]
        func carrier(_ value: MacIRValue) throws -> (String, Int) {
            guard case let .register(name, version) = value, version >= 0,
                  let n = A64MachineState.vectorIndex(name), name == "v\(n)" else { throw Failure.unsupported("NEON conversion buffer carrier") }
            return (name, version)
        }
        func read(_ value: MacIRValue) throws {
            let (name, version) = try carrier(value)
            guard version == versions[name, default: 0] else { throw Failure.unsupported("NEON conversion buffer stale/future source") }
        }
        func write(_ value: MacIRValue) throws {
            let (name, version) = try carrier(value)
            guard version == versions[name, default: 0] + 1 else { throw Failure.unsupported("NEON conversion buffer destination version") }
            versions[name] = version
        }
        for (position, instruction) in instructions.enumerated() {
            // Inspect every row, even one a retained frame dispatcher would skip.
            guard instruction.neonScalarVariableShift == nil, instruction.neonWiderChannelMemory == nil, instruction.neonMultiChannelLane == nil, instruction.neonWiderMultiChannelLane == nil, instruction.neonWiderMultiChannelReplicate == nil, instruction.neonScalarShiftCompilerComposition == nil, instruction.neonScalarMaskSelection == nil, instruction.neonScalarIntegerComparison == nil, instruction.neonMultiChannelReplicate == nil else { throw Failure.unsupported("new82 foreign metadata exclusion") }
            guard instruction.neonBitCount == nil, instruction.neonInterleavedMemory == nil,
                  instruction.neonBufferSequence == nil, instruction.neonBitView == nil,
                  instruction.neonReduction == nil, instruction.neonImmediate == nil,
                  instruction.neonMultiply == nil, instruction.neonShiftInsert == nil,
                  instruction.neonLogical == nil, instruction.neonExtract == nil,
                  instruction.neonPermutation == nil, instruction.neonModular == nil,
                  instruction.neonComparison == nil, instruction.neonTableLookup == nil,
                  instruction.scalarFP == nil else { throw Failure.unsupported("NEON conversion buffer excluded family") }
            let families = [instruction.neonPacking != nil, instruction.neonOrderConversion != nil,
                            instruction.neonIndexedMemory != nil, instruction.neonBufferMemory != nil].filter { $0 }.count
            guard families <= 1 else { throw Failure.unsupported("NEON conversion buffer competing metadata") }
            if position == instructions.count - 1 {
                guard families == 0, instruction.memoryAccess == nil,
                      instruction.operation == .returnValue(nil), instruction.returnTarget == .register(name: "x30", version: 0) else { throw Failure.unsupported("NEON conversion buffer terminal return") }
                continue
            }
            guard instruction.returnTarget == nil else { throw Failure.unsupported("NEON conversion buffer early return") }
            if instruction.neonPacking != nil || instruction.neonOrderConversion != nil {
                guard instruction.memoryAccess == nil,
                      case let .intrinsic(destination?, _, arguments) = instruction.operation,
                      arguments.count == (instruction.neonPacking?.readsDestination == true ? 2 : 1) else { throw Failure.unsupported("NEON conversion buffer producer shape") }
                for argument in arguments { try read(argument) }
                if instruction.neonPacking?.readsDestination == true {
                    let (name, version) = try carrier(destination), (oldName, oldVersion) = try carrier(arguments[1])
                    guard name == oldName, oldVersion == version - 1 else { throw Failure.unsupported("NEON conversion buffer old destination") }
                }
                try write(destination)
            } else if instruction.neonIndexedMemory != nil || instruction.neonBufferMemory != nil {
                let effect = instruction.neonIndexedMemory?.effect ?? instruction.neonBufferMemory!.effect
                let address = instruction.neonIndexedMemory?.address ?? instruction.neonBufferMemory!.address
                let sequence = instruction.neonIndexedMemory?.sequence ?? instruction.neonBufferMemory!.sequence
                guard sequence == ordinal, instruction.memoryAccess == .init(byteWidth: 16) else { throw Failure.unsupported("NEON conversion buffer Q ordinal/access") }
                switch (effect, instruction.operation) {
                case let (.load, .load(destination, actual)) where actual == address: try write(destination); loads += 1
                case let (.store, .store(source, actual)) where actual == address: try read(source); stores += 1
                default: throw Failure.unsupported("NEON conversion buffer memory shape")
                }
                ordinal += 1
            } else {
                guard instruction.memoryAccess == nil,
                      case .intrinsic(nil, "nop", let arguments) = instruction.operation, arguments.isEmpty else { throw Failure.unsupported("NEON conversion buffer untyped effect") }
            }
        }
        guard loads > 0, stores > 0 else { throw Failure.unsupported("NEON conversion buffer load/store") }
        return true
    }
}

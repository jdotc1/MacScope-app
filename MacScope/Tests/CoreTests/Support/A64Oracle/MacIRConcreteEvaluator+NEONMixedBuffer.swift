import Foundation
@testable import MacScope

extension MacIRConcreteEvaluator {
    /// Structural preflight only for the new mixed contract. No payload/state
    /// mutation and no duplicate memory implementation. Dynamic address/value
    /// checks remain the authoritative31/33 consumers' responsibility.
    func validateNEONMixedBuffer(_ instructions: [MacIRInstruction]) throws {
        guard !instructions.contains(where: { $0.neonLaneCoefficientProduct != nil || $0.neonReplicatedIndexedProduct != nil }) else { throw Failure.unsupported("replicated product marker in standalone family") }
        guard instructions.contains(where: { $0.neonBitView != nil }),
              instructions.contains(where: { $0.neonBufferMemory != nil || $0.neonBufferSequence != nil }) else { return }
        var memoryOrdinal = 0, position = 0
        func vector(_ value: MacIRValue, minimum: Int = 0) -> Bool {
            guard case let .register(name, version) = value,
                  let index = A64MachineState.vectorIndex(name) else { return false }
            return name == "v\(index)" && version >= minimum
        }
        for i in instructions {
            guard i.neonScalarVariableShift == nil, i.neonWiderChannelMemory == nil, i.neonMultiChannelLane == nil, i.neonWiderMultiChannelLane == nil, i.neonWiderMultiChannelReplicate == nil, i.neonScalarShiftCompilerComposition == nil, i.neonScalarMaskSelection == nil, i.neonScalarIntegerComparison == nil, i.neonMultiChannelReplicate == nil else { throw Failure.unsupported("new82 foreign metadata exclusion") }
            guard i.neonPermutation == nil, i.neonModular == nil, i.neonComparison == nil,
                  i.neonTableLookup == nil, i.neonShiftInsert == nil, i.neonMultiply == nil, i.neonImmediate == nil,
                  i.scalarFP == nil else { throw Failure.unsupported("outside mixed family union") }
            let primary = [i.neonBitView != nil, i.neonLogical != nil, i.neonExtract != nil,
                i.neonPermutation != nil, i.neonModular != nil, i.neonComparison != nil,
                i.neonTableLookup != nil, i.neonShiftInsert != nil, i.neonMultiply != nil, i.neonImmediate != nil,
                i.scalarFP != nil, i.neonBufferMemory != nil || i.neonBufferSequence != nil].filter { $0 }.count
            guard primary <= 1 else { throw Failure.unsupported("mixed competing effect descriptors") }
            if let bits = i.neonBitView {
                guard i.memoryAccess == nil, i.returnTarget == nil,
                      case let .intrinsic(destination?, _, args) = i.operation,
                      args.count == (bits.readsOldDestination ? 2 : 1) else { throw Failure.unsupported("mixed bit-view shape") }
                if bits.sourceIsGPR {
                    // Existing32 evaluates typed argument/cast/projected integer
                    // values, not only syntactic register nodes. Preserve that
                    // authority; exact dynamic width is checked by its consumer.
                    if case let .register(name, version) = args[0],
                       ["xzr", "wzr"].contains(name), version != 0 {
                        throw Failure.unsupported("mixed versioned zero source")
                    }
                } else if !vector(args[0]) { throw Failure.unsupported("mixed vector source") }
                if bits.resultIsGPR {
                    guard case let .register(name, version) = destination,
                          MacIRBuilder.bitViewGPR(name, width: bits.elementBits) != nil,
                          version >= 0, !["xzr", "wzr"].contains(name) || version == 0 else { throw Failure.unsupported("mixed GPR destination") }
                } else {
                    guard vector(destination, minimum: 1), case let .register(name, version) = destination else { throw Failure.unsupported("mixed vector destination") }
                    for arg in args where !bits.sourceIsGPR {
                        if case let .register(sourceName, sourceVersion) = arg, sourceName == name, sourceVersion >= version { throw Failure.unsupported("mixed source snapshot") }
                    }
                    if bits.readsOldDestination, args[1] != .register(name: name, version: version - 1) { throw Failure.unsupported("mixed old destination") }
                }
            }
        }
        while position < instructions.count {
            let i = instructions[position]
            if let step = i.neonBufferSequence {
                let plan = step.sequence
                guard step.ordinal == 0, plan.firstMemorySequence == memoryOrdinal,
                      plan.effectCount <= instructions.count - position else { throw Failure.unsupported("mixed frame boundary") }
                for ordinal in 0..<plan.effectCount {
                    let effect = instructions[position + ordinal]
                    guard effect.source.address == i.source.address,
                          effect.neonBufferSequence == .init(sequence: plan, ordinal: ordinal),
                          effect.operation == plan.operation(ordinal), effect.returnTarget == nil,
                          effect.neonBufferMemory == (ordinal < plan.vectors.count ? plan.memory(ordinal) : nil),
                          effect.memoryAccess == (ordinal < plan.vectors.count ? MacIRMemoryAccess(byteWidth: 16) : nil) else { throw Failure.unsupported("mixed frame identity/order") }
                }
                memoryOrdinal += plan.vectors.count; position += plan.effectCount; continue
            }
            if let memory = i.neonBufferMemory {
                guard memory.sequence == memoryOrdinal, i.memoryAccess == MacIRMemoryAccess(byteWidth: 16), i.returnTarget == nil else { throw Failure.unsupported("mixed memory ordinal/access") }
                let carrier: MacIRValue
                switch (memory.effect, i.operation) {
                case let (.load, .load(destination, address)) where address == memory.address: carrier = destination
                case let (.store, .store(source, address)) where address == memory.address: carrier = source
                default: throw Failure.unsupported("mixed memory operation")
                }
                guard vector(carrier, minimum: memory.effect == .load ? 1 : 0) else { throw Failure.unsupported("mixed memory carrier") }
                memoryOrdinal += 1
            }
            position += 1
        }
    }
}

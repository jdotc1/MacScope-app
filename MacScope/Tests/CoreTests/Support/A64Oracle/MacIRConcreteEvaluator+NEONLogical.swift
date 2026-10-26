import Foundation
@testable import MacScope

extension MacIRConcreteEvaluator {
    /// vN is a physical 128-bit carrier only on this typed route. Do not expand
    /// the evaluator's general scalar/q location map or alias inference.
    func readNEONRegister(_ value: MacIRValue) throws -> Scalar {
        guard case let .register(name, version) = value,
              let index = A64MachineState.vectorIndex(name), name == "v\(index)" else {
            throw Failure.unsupported("NEON register input")
        }
        if version == 0 {
            return Scalar(bits: state.v[index].low, width: 128, kind: .unsigned, high: state.v[index].high)
        }
        guard let value = ssa[value], value.width == 128 else { throw Failure.unsupported("NEON unwritten SSA input") }
        return value
    }

    /// Actual oracle consumer of typed IR. Does not consult source mnemonic/name.
    mutating func executeNEONLogical(_ descriptor: MacIRNEONLogical, operation: MacIROperation) throws {
        guard case let .intrinsic(destination?, _, arguments) = operation,
              arguments.count == (descriptor.readsDestination ? 3 : 2) else {
            throw Failure.unsupported("NEON logical operand shape")
        }
        let n = try readNEONRegister(arguments[0]), m = try readNEONRegister(arguments[1])
        let d = descriptor.readsDestination ? try readNEONRegister(arguments[2]) : Scalar(bits: 0, width: 128, kind: .unsigned)
        guard n.width == 128, m.width == 128, d.width == 128 else { throw Failure.unsupported("NEON logical input width") }
        let low = descriptor.evaluateHalf(n: n.bits, m: m.bits, oldDestination: d.bits)
        let high = descriptor.width == .bytes8 ? 0 : descriptor.evaluateHalf(n: n.high, m: m.high, oldDestination: d.high)
        try writeNEONRegister(destination, Scalar(bits: low, width: 128, kind: .unsigned, high: high))
    }

    /// General per-row lane operation (D06 region composition). Arguments are
    /// Vn, Vm (when present), then the old Vd when the form reads it.
    mutating func executeNEONLaneOp(_ descriptor: MacIRNEONLaneOp, operation: MacIROperation) throws {
        guard case let .intrinsic(destination?, _, arguments) = operation,
              arguments.count == descriptor.arity else {
            throw Failure.unsupported("NEON lane operand shape")
        }
        if descriptor.kind == .dup {
            // GPR broadcasts use the low lane; by-element DUPs select from
            // the full V-register carrier, including upper-half and SSA lanes.
            let source = try evaluate(arguments[0])
            let result = descriptor.evaluate(n: (source.bits, source.high))
            try writeNEONRegister(destination, Scalar(bits: result.low, width: 128, kind: .unsigned, high: result.high))
            return
        }
        let values = try arguments.map { try readNEONRegister($0) }
        guard values.allSatisfy({ $0.width == 128 }) else { throw Failure.unsupported("NEON lane input width") }
        let zero: MacIRNEONLaneOp.Vector = (0, 0)
        func vector(_ s: Scalar) -> MacIRNEONLaneOp.Vector { (s.bits, s.high) }
        let n = vector(values[0])
        let m = descriptor.sourceCount == 2 ? vector(values[1]) : zero
        let old = descriptor.readsDestination ? vector(values[values.count - 1]) : zero
        let result = descriptor.evaluate(n: n, m: m, oldDestination: old)
        // Sticky FPSR.QC (bit 27) on any saturated lane.
        if descriptor.saturates(n: n, m: m) { state.fpsr |= 1 << 27 }
        try writeNEONRegister(destination, Scalar(bits: result.low, width: 128, kind: .unsigned, high: result.high))
    }

    /// Consume the unchanged DOT04 typed lane route for newly admitted combined
    /// kernels. This is a consumer, not a change to DOT04 routing semantics.
    mutating func executeNEONPermutation(_ descriptor: MacIRNEONPermutation, operation: MacIROperation) throws {
        guard case let .intrinsic(destination?, _, arguments) = operation, arguments.count == 2 else { throw Failure.unsupported("NEON permutation operand shape") }
        let n = try readNEONRegister(arguments[0]), m = try readNEONRegister(arguments[1])
        guard n.width == 128, m.width == 128, [8,16].contains(descriptor.activeBytes), [1,2,4,8].contains(descriptor.laneBytes) else { throw Failure.unsupported("NEON permutation input width") }
        func bytes(_ s: Scalar) -> [UInt8] { (0..<16).map { UInt8(truncatingIfNeeded: ($0 < 8 ? s.bits : s.high) >> (($0 % 8) * 8)) } }
        let input = Array(bytes(n).prefix(descriptor.activeBytes)) + Array(bytes(m).prefix(descriptor.activeBytes))
        var output = [UInt8](repeating: 0, count: 16)
        for (lane, source) in descriptor.sourceLanes.enumerated() {
            guard source >= 0, source < 2 * descriptor.laneCount else { throw Failure.unsupported("NEON permutation lane") }
            for byte in 0..<descriptor.laneBytes { output[lane * descriptor.laneBytes + byte] = input[source * descriptor.laneBytes + byte] }
        }
        func half(_ base: Int) -> UInt64 { (0..<8).reduce(0) { $0 | (UInt64(output[base + $1]) << ($1 * 8)) } }
        try writeNEONRegister(destination, Scalar(bits: half(0), width: 128, kind: .unsigned, high: half(8)))
    }
}

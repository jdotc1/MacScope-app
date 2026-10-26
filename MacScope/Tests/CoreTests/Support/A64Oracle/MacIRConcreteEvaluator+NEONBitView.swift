import Foundation
@testable import MacScope

extension MacIRConcreteEvaluator {
    mutating func executeNEONBitView(_ descriptor: MacIRNEONBitView, operation: MacIROperation) throws {
        guard case let .intrinsic(destination?, _, arguments) = operation,
              arguments.count == (descriptor.readsOldDestination ? 2 : 1) else { throw Failure.unsupported("NEON bit-view shape") }
        let source: Scalar
        if descriptor.sourceIsGPR {
            source = try evaluate(arguments[0])
            guard source.kind != .float, source.width == max(32, descriptor.elementBits) else { throw Failure.unsupported("NEON bit-view GPR source") }
        } else { source = try readNEONRegister(arguments[0]) }
        if descriptor.resultIsGPR {
            guard case let .register(name, _) = destination,
                  MacIRBuilder.bitViewGPR(name, width: max(32, descriptor.elementBits)) != nil else { throw Failure.unsupported("NEON bit-view GPR destination") }
            // Discard means no architectural or SSA write, not an SSA-only value.
            if name == "wzr" || name == "xzr" { return }
            try write(destination, .int(descriptor.selectedBits(low: source.bits, high: source.high), width: max(32, descriptor.elementBits), signed: false))
        } else {
            let old = descriptor.readsOldDestination ? try readNEONRegister(arguments[1]) : Scalar(bits: 0, width: 128, kind: .unsigned)
            let result = descriptor.vectorBits(sourceLow: source.bits, sourceHigh: source.high, oldLow: old.bits, oldHigh: old.high)
            try writeNEONRegister(destination, .init(bits: result.low, width: 128, kind: .unsigned, high: result.high))
        }
    }
}

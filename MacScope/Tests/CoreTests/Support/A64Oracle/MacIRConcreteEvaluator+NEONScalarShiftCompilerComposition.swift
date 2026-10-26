import Foundation
#if canImport(MacScope)
@testable import MacScope
#endif

extension MacIRConcreteEvaluator {
    mutating func executeNEONScalarShiftCompilerComposition(_ marker: MacIRNEONScalarShiftCompilerComposition, instruction: MacIRInstruction) throws {
        guard marker.kind == .insert, let descriptor = instruction.neonBitView,
              descriptor.kind == .insertElement, descriptor.elementBits == 64,
              descriptor.destinationLane == 0, descriptor.sourceLane == 0, descriptor.activeBytes == 16,
              case let .intrinsic(destination?, _, arguments) = instruction.operation, arguments.count == 2,
              case let .register(sourceName, _) = arguments[0], sourceName == "x8" else {
            throw Failure.unsupported("scalar shift compiler exact GPR D0 insertion")
        }
        // Both snapshots precede destination write, including aliased OLD views.
        let source = try evaluate(arguments[0]), old = try readNEONRegister(arguments[1])
        guard source.width == 64, source.kind != .float, old.width == 128, old.high == 0 else {
            throw Failure.unsupported("scalar shift compiler raw64/zero OLDhigh complement")
        }
        let output = descriptor.vectorBits(sourceLow: source.bits, sourceHigh: 0, oldLow: old.bits, oldHigh: old.high)
        try writeNEONRegister(destination, .init(bits: output.low, width: 128, kind: .unsigned, high: output.high))
    }
}

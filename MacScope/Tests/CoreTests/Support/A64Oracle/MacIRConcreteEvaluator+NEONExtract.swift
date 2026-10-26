import Foundation
@testable import MacScope

extension MacIRConcreteEvaluator {
    /// Dispatch depends exclusively on typed metadata, never diagnostic text.
    mutating func executeNEONExtract(_ descriptor: MacIRNEONExtract, operation: MacIROperation) throws {
        guard case let .intrinsic(destination?, _, arguments) = operation, arguments.count == 2 else {
            throw Failure.unsupported("NEON EXT operand shape")
        }
        let n = try readNEONRegister(arguments[0]), m = try readNEONRegister(arguments[1])
        let result = descriptor.evaluate(nLow: n.bits, nHigh: n.high, mLow: m.bits, mHigh: m.high)
        try writeNEONRegister(destination, Scalar(bits: result.low, width: 128, kind: .unsigned, high: result.high))
    }
}

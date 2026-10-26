import Foundation
@testable import MacScope

extension MacIRConcreteEvaluator {
    mutating func executeNEONComparison(_ descriptor: MacIRNEONComparison, operation: MacIROperation) throws {
        guard case let .intrinsic(destination?, _, arguments) = operation, arguments.count == 2 else {
            throw Failure.unsupported("NEON comparison operand shape")
        }
        let lhs = try readNEONRegister(arguments[0]), rhs = try readNEONRegister(arguments[1])
        let result = descriptor.evaluate((lhs.bits, lhs.high), (rhs.bits, rhs.high))
        try writeNEONRegister(destination, Scalar(bits: result.low, width: 128, kind: .unsigned, high: result.high))
    }
}

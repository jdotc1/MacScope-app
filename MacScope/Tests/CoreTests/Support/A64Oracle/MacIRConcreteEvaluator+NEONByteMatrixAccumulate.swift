import Foundation
#if canImport(MacScope)
@testable import MacScope
#endif

extension MacIRConcreteEvaluator {
    mutating func executeNEONByteMatrixAccumulate(_ descriptor: MacIRNEONByteMatrixAccumulate, operation: MacIROperation) throws {
        guard case let .intrinsic(destination?, _, arguments) = operation, arguments.count == 3 else { throw Failure.unsupported("byte matrix accumulation intrinsic") }
        let first = try readNEONRegister(arguments[0])
        let second = try readNEONRegister(arguments[1])
        let old = try readNEONRegister(arguments[2])
        guard first.width == 128, second.width == 128, old.width == 128 else { throw Failure.unsupported("byte matrix accumulation full128 captures") }
        let result = descriptor.evaluate(first: (first.bits, first.high), second: (second.bits, second.high), old: (old.bits, old.high))
        try writeNEONRegister(destination, .init(bits: result.low, width: 128, kind: .unsigned, high: result.high))
    }
}

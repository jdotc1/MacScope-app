import Foundation
@testable import MacScope

extension MacIRConcreteEvaluator {
    mutating func executeNEONTableLookup(_ descriptor: MacIRNEONTableLookup, operation: MacIROperation) throws {
        guard case let .intrinsic(destination?, _, arguments) = operation, (descriptor.kind == .tbl
                ? [descriptor.tableCount + 1, descriptor.tableCount + 2].contains(arguments.count)
                : arguments.count == descriptor.tableCount + 2) else {
            throw Failure.unsupported("NEON table lookup operand shape")
        }
        // Legacy TBL emitters carried an unused old destination; do not evaluate it.
        let required = descriptor.tableCount + (descriptor.kind == .tbx ? 2 : 1)
        let values = try arguments.prefix(required).map { try readNEONRegister($0) }
        let tables = values.prefix(descriptor.tableCount).map { (low: $0.bits, high: $0.high) }
        let index = values[descriptor.tableCount]
        let old = descriptor.kind == .tbx ? values[descriptor.tableCount + 1] : Scalar(bits: 0, width: 128, kind: .unsigned)
        guard let result = descriptor.evaluate(tables: tables, index: (index.bits, index.high), old: (old.bits, old.high)) else {
            throw Failure.unsupported("NEON table extent")
        }
        try writeNEONRegister(destination, Scalar(bits: result.low, width: 128, kind: .unsigned, high: result.high))
    }
}

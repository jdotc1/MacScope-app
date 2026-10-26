/*
Ported from EntitlementDiff.

MIT License

Copyright (c) 2026 EntitlementDiff contributors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
*/

import CoreFoundation
import Foundation

public enum EntitlementDataError: Error, Sendable, Equatable, LocalizedError {
    case invalidRoot
    case unsupportedType(String)
    case invalidNumber(String)
    case nonFiniteNumber
    case nonFiniteDate
    case limitExceeded(String)
    case invalidLimits
    case duplicateKey(String)

    public var errorDescription: String? {
        switch self {
        case .invalidRoot: "Expected an entitlement dictionary with string keys."
        case .unsupportedType(let type): "Unsupported entitlement value type: \(type)."
        case .invalidNumber(let number): "Unsupported numeric representation: \(DisplayText.escaped(number))."
        case .nonFiniteNumber: "An entitlement contains a nonfinite real number."
        case .nonFiniteDate: "An entitlement contains a nonfinite date."
        case .limitExceeded(let budget): "Entitlement conversion exceeded its \(budget) limit."
        case .invalidLimits: "Conversion limits must be positive."
        case .duplicateKey(let key): "Duplicate entitlement key: \(DisplayText.quoted(key))."
        }
    }
}

public struct DecodeLimits: Sendable {
    public let maxDepth: Int
    public let maxNodes: Int
    public let maxBytes: Int

    public init(maxDepth: Int = 32, maxNodes: Int = 100_000, maxBytes: Int = 8 * 1_024 * 1_024) {
        self.maxDepth = maxDepth
        self.maxNodes = maxNodes
        self.maxBytes = maxBytes
    }
}

/// Bounds conversion after Foundation/Security has produced its object graph.
/// It cannot bound the native parser's earlier memory use or execution time.
public struct FoundationEntitlementDecoder: Sendable {
    public let limits: DecodeLimits
    public init(limits: DecodeLimits = .init()) { self.limits = limits }

    public func decode(_ object: Any) throws -> EntitlementDictionary {
        guard limits.maxDepth > 0, limits.maxNodes > 0, limits.maxBytes > 0 else {
            throw EntitlementDataError.invalidLimits
        }
        guard object is NSDictionary else { throw EntitlementDataError.invalidRoot }
        var budget = Budget(nodes: limits.maxNodes, bytes: limits.maxBytes)
        let value = try convert(object, depth: 0, budget: &budget)
        guard case .dictionary(let dictionary) = value else { throw EntitlementDataError.invalidRoot }
        return dictionary
    }

    private func convert(_ object: Any, depth: Int, budget: inout Budget) throws -> EntitlementValue {
        guard depth <= limits.maxDepth else { throw EntitlementDataError.limitExceeded("nesting depth") }
        try budget.node()
        // NSDecimalNumber is not an exact binary property-list real. Silently
        // coercing its decimal payload through doubleValue can lose precision.
        if object is NSDecimalNumber { throw EntitlementDataError.unsupportedType("NSDecimalNumber") }
        if let number = object as? NSNumber {
            try budget.consume(8)
            // `as? Bool` also accepts NSNumber(1); inspect the CF type instead.
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return .boolean(number.boolValue) }
            let type = String(cString: number.objCType)
            if type == "f" || type == "d" {
                guard number.doubleValue.isFinite else { throw EntitlementDataError.nonFiniteNumber }
                return .real(number.doubleValue)
            }
            let decimal = number.stringValue
            if let value = Int64(decimal) { return .integer(value) }
            if let value = UInt64(decimal) { return .unsignedInteger(value) }
            throw EntitlementDataError.invalidNumber(decimal)
        }
        if let string = object as? String {
            try budget.consume(string.utf8.count)
            return .string(string)
        }
        if let data = object as? Data {
            try budget.consume(data.count)
            return .data(data)
        }
        if let date = object as? Date {
            try budget.consume(8)
            guard date.timeIntervalSinceReferenceDate.isFinite else { throw EntitlementDataError.nonFiniteDate }
            return .date(date)
        }
        if let array = object as? NSArray {
            try budget.checkChildren(array.count)
            var values: [EntitlementValue] = []
            values.reserveCapacity(array.count)
            for index in 0..<array.count {
                values.append(try convert(array.object(at: index), depth: depth + 1, budget: &budget))
            }
            return .array(values)
        }
        if let dictionary = object as? NSDictionary {
            try budget.checkChildren(dictionary.count)
            var entries: [EntitlementEntry] = []
            entries.reserveCapacity(dictionary.count)
            for rawKey in dictionary.keyEnumerator() {
                guard let key = rawKey as? String, let value = dictionary.object(forKey: rawKey) else {
                    throw EntitlementDataError.invalidRoot
                }
                try budget.consume(key.utf8.count)
                entries.append(.init(key: key, value: try convert(value, depth: depth + 1, budget: &budget)))
            }
            return .dictionary(try .init(entries: entries))
        }
        throw EntitlementDataError.unsupportedType(String(describing: type(of: object)))
    }

    private struct Budget {
        var nodes: Int
        var bytes: Int
        mutating func node() throws {
            guard nodes > 0 else { throw EntitlementDataError.limitExceeded("node count") }
            nodes -= 1
        }
        func checkChildren(_ count: Int) throws {
            guard count <= nodes else { throw EntitlementDataError.limitExceeded("node count") }
        }
        mutating func consume(_ count: Int) throws {
            guard count <= bytes else { throw EntitlementDataError.limitExceeded("decoded byte count") }
            bytes -= count
        }
    }
}

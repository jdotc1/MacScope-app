import Foundation

/// Structural checks Foundation does not expose after it has materialized a
/// dictionary. In particular, duplicate binary-plist dictionary keys must be
/// rejected before they can collapse into one Swift dictionary entry.
enum NativeDecompilerWireBinaryPropertyListValidator {
    static func validate(_ data: Data) throws {
        var scanner = Scanner(data: data)
        try scanner.validate()
    }
}

private extension NativeDecompilerWireBinaryPropertyListValidator {
    enum Limits {
        // Defense-in-depth work ceilings derived beneath the 64 MiB outer
        // response limit. They bound compact object-graph amplification, for
        // which encoded byte size alone is not a useful measure of work.
        static let objectCount = 1_000_000
        static let dictionaryCount = 250_000
        static let keyReferenceCount = 2_000_000
        static let traversalReferenceCount = 4_000_000
        static let uniqueEncodedKeyBytes = 8 * 1_024 * 1_024
        static let uniqueDecodedKeyBytes = 8 * 1_024 * 1_024
        static let objectGraphDepth = 128
    }

    enum ValidationError: Error {
        case malformed
        case duplicateKey
        case resourceLimitExceeded
    }

    struct Scanner {
        private enum VisitState: UInt8 {
            case unseen
            case visiting
            case visited
        }

        private enum WorkItem {
            case enter(Int)
            case leave(Int, children: [Int])
        }

        private struct DecodedKey {
            let value: String
            let encodedByteCount: Int
            let decodedByteCount: Int
        }

        let data: Data
        private var offsets: [Int] = []
        private var referenceSize = 0
        private var objectTableEnd = 0
        private var visitStates: [VisitState] = []
        private var objectGraphDepths: [Int] = []
        private var decodedKeys: [Int: DecodedKey] = [:]
        private var dictionaryCount = 0
        private var keyReferenceCount = 0
        private var traversalReferenceCount = 0
        private var uniqueEncodedKeyBytes = 0
        private var uniqueDecodedKeyBytes = 0

        mutating func validate() throws {
            guard data.count >= 40,
                  String(data: data.prefix(8), encoding: .ascii) == "bplist00"
            else { throw ValidationError.malformed }

            let trailer = data.count - 32
            let offsetSize = Int(data[trailer + 6])
            referenceSize = Int(data[trailer + 7])
            let rawObjectCount = try integer(at: trailer + 8, byteCount: 8, upperBound: data.count)
            let topObject = try integer(at: trailer + 16, byteCount: 8, upperBound: data.count)
            let rawOffsetTable = try integer(at: trailer + 24, byteCount: 8, upperBound: data.count)
            guard (1...8).contains(offsetSize),
                  (1...8).contains(referenceSize),
                  rawObjectCount > 0,
                  rawObjectCount <= UInt64(Limits.objectCount),
                  topObject < rawObjectCount,
                  rawOffsetTable >= 8,
                  rawOffsetTable <= UInt64(trailer)
            else {
                if rawObjectCount > UInt64(Limits.objectCount) {
                    throw ValidationError.resourceLimitExceeded
                }
                throw ValidationError.malformed
            }

            let count = Int(rawObjectCount)
            objectTableEnd = Int(rawOffsetTable)
            guard count <= (trailer - objectTableEnd) / offsetSize else {
                throw ValidationError.malformed
            }

            offsets.reserveCapacity(count)
            for index in 0..<count {
                let entryOffset = objectTableEnd + index * offsetSize
                let rawOffset = try integer(
                    at: entryOffset,
                    byteCount: offsetSize,
                    upperBound: trailer
                )
                guard rawOffset >= 8, rawOffset < UInt64(objectTableEnd) else {
                    throw ValidationError.malformed
                }
                offsets.append(Int(rawOffset))
            }

            visitStates = Array(repeating: .unseen, count: count)
            objectGraphDepths = Array(repeating: 0, count: count)
            try traverse(from: Int(topObject))
        }

        mutating func traverse(from topObject: Int) throws {
            var work: [WorkItem] = [.enter(topObject)]
            while let item = work.popLast() {
                switch item {
                case let .leave(index, children):
                    guard visitStates[index] == .visiting else {
                        throw ValidationError.malformed
                    }
                    var childDepth = 0
                    for child in children {
                        childDepth = max(childDepth, objectGraphDepths[child])
                    }
                    guard childDepth < Limits.objectGraphDepth else {
                        throw ValidationError.resourceLimitExceeded
                    }
                    objectGraphDepths[index] = childDepth + 1
                    visitStates[index] = .visited

                case let .enter(index):
                    switch visitStates[index] {
                    case .visited:
                        continue
                    case .visiting:
                        throw ValidationError.malformed
                    case .unseen:
                        visitStates[index] = .visiting
                    }

                    let children = try childReferences(of: index)
                    work.append(.leave(index, children: children))
                    for child in children.reversed() {
                        guard child < offsets.count else {
                            throw ValidationError.malformed
                        }
                        work.append(.enter(child))
                    }
                }
            }
        }

        mutating func childReferences(of objectIndex: Int) throws -> [Int] {
            let offset = offsets[objectIndex]
            guard offset < objectTableEnd else { throw ValidationError.malformed }
            switch data[offset] >> 4 {
            case 0xA, 0xB, 0xC:
                let (count, referencesStart) = try collectionCount(at: offset)
                try validateReferencePayload(
                    count: count,
                    referencesStart: referencesStart,
                    arraysPerElement: 1
                )
                try addToTraversalReferenceCount(count)
                return try references(count: count, startingAt: referencesStart)

            case 0xD:
                return try dictionaryValueReferences(at: offset)

            default:
                return []
            }
        }

        mutating func dictionaryValueReferences(at offset: Int) throws -> [Int] {
            dictionaryCount += 1
            guard dictionaryCount <= Limits.dictionaryCount else {
                throw ValidationError.resourceLimitExceeded
            }

            let (count, referencesStart) = try collectionCount(at: offset)
            try addToKeyReferenceCount(count)
            try validateReferencePayload(
                count: count,
                referencesStart: referencesStart,
                arraysPerElement: 2
            )
            try addToTraversalReferenceCount(count)

            var keys = Set<String>()
            keys.reserveCapacity(min(count, 4_096))
            for index in 0..<count {
                let reference = try reference(
                    at: referencesStart + index * referenceSize
                )
                let key = try decodedKey(at: reference)
                guard keys.insert(key).inserted else {
                    throw ValidationError.duplicateKey
                }
            }

            let valuesStart = referencesStart + count * referenceSize
            return try references(count: count, startingAt: valuesStart)
        }

        mutating func decodedKey(at objectIndex: Int) throws -> String {
            guard objectIndex < offsets.count else { throw ValidationError.malformed }
            if let cached = decodedKeys[objectIndex] {
                return cached.value
            }

            let decoded = try string(at: offsets[objectIndex])
            guard decoded.encodedByteCount <= Limits.uniqueEncodedKeyBytes - uniqueEncodedKeyBytes,
                  decoded.decodedByteCount <= Limits.uniqueDecodedKeyBytes - uniqueDecodedKeyBytes
            else { throw ValidationError.resourceLimitExceeded }

            uniqueEncodedKeyBytes += decoded.encodedByteCount
            uniqueDecodedKeyBytes += decoded.decodedByteCount
            decodedKeys[objectIndex] = decoded
            return decoded.value
        }

        mutating func addToKeyReferenceCount(_ count: Int) throws {
            guard count <= Limits.keyReferenceCount - keyReferenceCount else {
                throw ValidationError.resourceLimitExceeded
            }
            keyReferenceCount += count
        }

        mutating func addToTraversalReferenceCount(_ count: Int) throws {
            guard count <= Limits.traversalReferenceCount - traversalReferenceCount else {
                throw ValidationError.resourceLimitExceeded
            }
            traversalReferenceCount += count
        }

        func validateReferencePayload(
            count: Int,
            referencesStart: Int,
            arraysPerElement: Int
        ) throws {
            guard referencesStart <= objectTableEnd,
                  arraysPerElement > 0,
                  referenceSize <= Int.max / arraysPerElement
            else { throw ValidationError.malformed }
            let bytesPerElement = referenceSize * arraysPerElement
            guard count <= (objectTableEnd - referencesStart) / bytesPerElement else {
                throw ValidationError.malformed
            }
        }

        func references(count: Int, startingAt start: Int) throws -> [Int] {
            var result = [Int]()
            result.reserveCapacity(min(count, Limits.objectCount))
            for index in 0..<count {
                result.append(try reference(at: start + index * referenceSize))
            }
            return result
        }

        func reference(at offset: Int) throws -> Int {
            let rawReference = try integer(
                at: offset,
                byteCount: referenceSize,
                upperBound: objectTableEnd
            )
            guard rawReference < UInt64(offsets.count) else {
                throw ValidationError.malformed
            }
            return Int(rawReference)
        }

        func collectionCount(at offset: Int) throws -> (count: Int, payloadStart: Int) {
            guard offset >= 8, offset < objectTableEnd else {
                throw ValidationError.malformed
            }
            let inlineCount = Int(data[offset] & 0x0F)
            if inlineCount < 0x0F { return (inlineCount, offset + 1) }

            let integerOffset = offset + 1
            guard integerOffset < objectTableEnd, data[integerOffset] >> 4 == 0x1 else {
                throw ValidationError.malformed
            }
            let exponent = Int(data[integerOffset] & 0x0F)
            guard exponent <= 3 else { throw ValidationError.malformed }
            let byteCount = 1 << exponent
            let count = try integer(
                at: integerOffset + 1,
                byteCount: byteCount,
                upperBound: objectTableEnd
            )
            guard count <= UInt64(Int.max) else { throw ValidationError.malformed }
            return (Int(count), integerOffset + 1 + byteCount)
        }

        private func string(at offset: Int) throws -> DecodedKey {
            guard offset >= 8, offset < objectTableEnd else {
                throw ValidationError.malformed
            }
            let kind = data[offset] >> 4
            let (count, payloadStart) = try collectionCount(at: offset)
            switch kind {
            case 0x5, 0x7:
                guard payloadStart <= objectTableEnd,
                      count <= objectTableEnd - payloadStart
                else { throw ValidationError.malformed }
                guard count <= Limits.uniqueEncodedKeyBytes else {
                    throw ValidationError.resourceLimitExceeded
                }
                let bytes = data[payloadStart..<(payloadStart + count)]
                guard let value = String(data: bytes, encoding: kind == 0x5 ? .ascii : .utf8) else {
                    throw ValidationError.malformed
                }
                return DecodedKey(
                    value: value,
                    encodedByteCount: count,
                    decodedByteCount: value.utf8.count
                )

            case 0x6:
                guard payloadStart <= objectTableEnd,
                      count <= (objectTableEnd - payloadStart) / 2
                else { throw ValidationError.malformed }
                guard count <= Limits.uniqueEncodedKeyBytes / 2 else {
                    throw ValidationError.resourceLimitExceeded
                }
                var codeUnits = [UInt16]()
                codeUnits.reserveCapacity(count)
                for index in 0..<count {
                    let unit = try integer(
                        at: payloadStart + index * 2,
                        byteCount: 2,
                        upperBound: objectTableEnd
                    )
                    codeUnits.append(UInt16(unit))
                }
                let value = String(decoding: codeUnits, as: UTF16.self)
                return DecodedKey(
                    value: value,
                    encodedByteCount: count * 2,
                    decodedByteCount: value.utf8.count
                )

            default:
                throw ValidationError.malformed
            }
        }

        func integer(at offset: Int, byteCount: Int, upperBound: Int) throws -> UInt64 {
            guard byteCount > 0,
                  byteCount <= 8,
                  offset >= 0,
                  upperBound <= data.count,
                  offset <= upperBound - byteCount
            else { throw ValidationError.malformed }
            var value: UInt64 = 0
            for index in 0..<byteCount {
                value = (value << 8) | UInt64(data[offset + index])
            }
            return value
        }
    }
}

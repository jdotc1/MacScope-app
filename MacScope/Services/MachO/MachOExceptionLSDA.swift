import Foundation

/// Bounded structural LSDA facts. These records do not establish runtime type
/// matching, personality identity, or observed exceptional control flow.
enum MachOExceptionLSDA {
    enum ParseError: Error, Equatable {
        case malformed(String)
        case unsupportedEncoding(UInt8)
        case limit
    }

    enum Pointer: Equatable, Sendable {
        case direct(UInt64)
        case indirectSlot(UInt64)
    }

    struct CallSite: Equatable, Sendable {
        let protectedRange: Range<UInt64>
        let landingPad: UInt64?
        let actionOffset: UInt64
        let actionChain: [Int]
        let source: Range<Int>
    }

    struct Action: Equatable, Sendable {
        let offset: Int
        let filter: Int64
        let nextOffset: Int?
        let typeIndex: UInt64?
        let specificationIndexes: [UInt64]
        /// Includes the terminating zero, including for an empty specification.
        let specificationSource: Range<Int>?
        let source: Range<Int>
    }

    struct TypeEntry: Equatable, Sendable {
        let index: UInt64
        let pointer: Pointer
        let source: Range<Int>
    }

    struct Report: Equatable, Sendable {
        let address: UInt64
        let functionStart: UInt64
        let functionEnd: UInt64
        let landingPadBase: UInt64
        let headerSource: Range<Int>
        let callsites: [CallSite]
        let actions: [Action]
        let types: [TypeEntry]
    }

    static func parse(data: Data, address: UInt64, functionStart: UInt64,
                      functionEnd: UInt64) throws -> Report {
        guard data.count <= 1_048_576 else { throw ParseError.limit }
        guard functionStart < functionEnd,
              !address.addingReportingOverflow(UInt64(data.count)).overflow else {
            throw ParseError.malformed("invalid address extent")
        }
        var parser = Parser(reader: LittleEndianReader(data), address: address,
                            functionStart: functionStart, functionEnd: functionEnd,
                            claims: [UInt8](repeating: 0, count: data.count))
        return try parser.parse()
    }

    private struct Parser {
        let reader: LittleEndianReader
        let address: UInt64
        let functionStart: UInt64
        let functionEnd: UInt64
        var claims: [UInt8]
        var steps = 0
        var actionBegin = 0
        var typeBase: Int?
        var typeEncoding: UInt8 = 0xff
        var actions: [Int: Action] = [:]
        var types: [UInt64: TypeEntry] = [:]
        var specificationItems: [Int: Int] = [:]
        var specificationCount = 0

        mutating func tick(_ cost: Int = 1) throws {
            guard cost <= 131_072 - steps else { throw ParseError.limit }
            steps += cost
        }

        func add(_ a: UInt64, _ b: UInt64) throws -> UInt64 {
            let value = a.addingReportingOverflow(b)
            guard !value.overflow else { throw ParseError.malformed("address overflow") }
            return value.partialValue
        }

        func addSigned(_ base: UInt64, _ displacement: Int64) throws -> UInt64 {
            if displacement >= 0 { return try add(base, UInt64(displacement)) }
            let value = base.subtractingReportingOverflow(displacement.magnitude)
            guard !value.overflow else { throw ParseError.malformed("address underflow") }
            return value.partialValue
        }

        mutating func byte(_ cursor: inout Int, end: Int) throws -> UInt8 {
            try tick()
            guard cursor < end, let value = reader.byte(cursor) else {
                throw ParseError.malformed("truncated LSDA")
            }
            cursor += 1
            return value
        }

        mutating func leb(_ cursor: inout Int, end: Int, signed: Bool = false) throws -> UInt64 {
            var value: UInt64 = 0
            for group in 0..<10 {
                let b = try byte(&cursor, end: end)
                let payload = b & 0x7f
                if group == 9 {
                    guard b & 0x80 == 0,
                          (signed ? (payload == 0 || payload == 0x7f) : payload <= 1) else {
                        throw ParseError.malformed("LEB128 overflow")
                    }
                }
                value |= UInt64(group == 9 ? payload & 1 : payload) << (group * 7)
                if b & 0x80 == 0 {
                    let bits = (group + 1) * 7
                    if signed, bits < 64, b & 0x40 != 0 { value |= UInt64.max << bits }
                    return value
                }
            }
            throw ParseError.malformed("unterminated LEB128")
        }

        func width(_ encoding: UInt8) -> Int? {
            switch encoding & 15 {
            case 0, 4, 12: return 8
            case 2, 10: return 2
            case 3, 11: return 4
            default: return nil
            }
        }

        mutating func scalar(_ cursor: inout Int, end: Int, encoding: UInt8) throws -> UInt64 {
            let format = encoding & 15
            if format == 1 || format == 9 {
                return try leb(&cursor, end: end, signed: format == 9)
            }
            guard let count = width(encoding) else { throw ParseError.unsupportedEncoding(encoding) }
            guard cursor <= end, count <= end - cursor else {
                throw ParseError.malformed("truncated scalar")
            }
            try tick()
            defer { cursor += count }
            switch format {
            case 0, 4, 12: return try reader.u64(cursor)
            case 2: return UInt64(try reader.u16(cursor))
            case 3: return UInt64(try reader.u32(cursor))
            case 10: return UInt64(bitPattern: Int64(Int16(bitPattern: try reader.u16(cursor))))
            case 11: return UInt64(bitPattern: Int64(Int32(bitPattern: try reader.u32(cursor))))
            default: throw ParseError.unsupportedEncoding(encoding)
            }
        }

        mutating func pointer(_ cursor: inout Int, end: Int, encoding: UInt8) throws -> Pointer {
            let application = encoding & 0x70
            guard encoding != 0xff, [UInt8(0), 0x10, 0x40].contains(application) else {
                throw ParseError.unsupportedEncoding(encoding)
            }
            let field = cursor
            let raw = try scalar(&cursor, end: end, encoding: encoding)
            if raw == 0 { return .direct(0) }
            let target: UInt64
            if application == 0 { target = raw }
            else {
                let base = application == 0x10 ? try add(address, UInt64(field)) : functionStart
                let format = encoding & 15
                target = (format == 0 || format >= 9)
                    ? try addSigned(base, Int64(bitPattern: raw)) : try add(base, raw)
            }
            return encoding & 0x80 == 0 ? .direct(target) : .indirectSlot(target)
        }

        mutating func claim(_ range: Range<Int>, kind: UInt8) throws {
            guard range.lowerBound >= 0, range.upperBound <= claims.count else {
                throw ParseError.malformed("source outside LSDA")
            }
            try tick(range.count)
            for offset in range {
                guard claims[offset] == 0 else { throw ParseError.malformed("overlapping metadata") }
            }
            for offset in range { claims[offset] = kind }
        }

        mutating func readType(_ index: UInt64) throws {
            try tick()
            if types[index] != nil { return }
            guard types.count < 4096 else { throw ParseError.limit }
            guard index > 0, let base = typeBase, let size = width(typeEncoding),
                  index <= UInt64(base / size) else {
                throw ParseError.malformed("invalid type table index or encoding")
            }
            let start = base - Int(index) * size
            guard start >= actionBegin else { throw ParseError.malformed("type overlaps call sites") }
            var cursor = start
            let value = try pointer(&cursor, end: base, encoding: typeEncoding)
            try claim(start..<cursor, kind: 4)
            types[index] = TypeEntry(index: index, pointer: value, source: start..<cursor)
        }

        mutating func readAction(_ offset: Int) throws -> Action {
            try tick()
            if let action = actions[offset] { return action }
            guard actions.count < 8192 else { throw ParseError.limit }
            let end = typeBase ?? reader.bytes.count
            guard offset >= actionBegin, offset < end else {
                throw ParseError.malformed("action outside action table")
            }
            var cursor = offset
            let filter = Int64(bitPattern: try leb(&cursor, end: end, signed: true))
            let linkField = cursor
            let displacement = Int64(bitPattern: try leb(&cursor, end: end, signed: true))
            let next: Int?
            if displacement == 0 { next = nil }
            else {
                let value = try addSigned(UInt64(linkField), displacement)
                guard value >= UInt64(actionBegin), value < UInt64(end) else {
                    throw ParseError.malformed("action link outside action table")
                }
                next = Int(value)
            }
            try claim(offset..<cursor, kind: 3)
            var indexes: [UInt64] = []
            var specificationSource: Range<Int>?
            if filter > 0 { try readType(UInt64(filter)) }
            else if filter < 0 {
                guard let base = typeBase else { throw ParseError.malformed("specification lacks type table") }
                let start = try add(UInt64(base), UInt64(-(filter + 1)))
                guard start < UInt64(reader.bytes.count) else {
                    throw ParseError.malformed("specification outside LSDA")
                }
                var specCursor = Int(start)
                while true {
                    let itemStart = specCursor
                    let index = try leb(&specCursor, end: reader.bytes.count)
                    if let existingEnd = specificationItems[itemStart] {
                        guard existingEnd == specCursor else { throw ParseError.malformed("specification boundary conflict") }
                    } else {
                        try claim(itemStart..<specCursor, kind: 5)
                        specificationItems[itemStart] = specCursor
                    }
                    if index == 0 { break }
                    guard specificationCount < 4096 else { throw ParseError.limit }
                    specificationCount += 1
                    try readType(index)
                    indexes.append(index)
                }
                specificationSource = Int(start)..<specCursor
            }
            let result = Action(offset: offset, filter: filter, nextOffset: next,
                                typeIndex: filter > 0 ? UInt64(filter) : nil,
                                specificationIndexes: indexes,
                                specificationSource: specificationSource, source: offset..<cursor)
            actions[offset] = result
            return result
        }

        mutating func parse() throws -> Report {
            let end = reader.bytes.count
            var cursor = 0
            let lpEncoding = try byte(&cursor, end: end)
            let lpBase: UInt64
            if lpEncoding == 0xff { lpBase = functionStart }
            else {
                guard case .direct(let value) = try pointer(&cursor, end: end, encoding: lpEncoding) else {
                    throw ParseError.unsupportedEncoding(lpEncoding)
                }
                lpBase = value
            }
            typeEncoding = try byte(&cursor, end: end)
            if typeEncoding != 0xff {
                let distance = try leb(&cursor, end: end)
                guard distance <= UInt64(end - cursor) else { throw ParseError.malformed("type base outside LSDA") }
                typeBase = cursor + Int(distance)
            }
            let callEncoding = try byte(&cursor, end: end)
            guard callEncoding & 0xf0 == 0,
                  width(callEncoding) != nil || callEncoding == 1 || callEncoding == 9 else {
                throw ParseError.unsupportedEncoding(callEncoding)
            }
            let size = try leb(&cursor, end: end)
            guard size <= UInt64(end - cursor) else { throw ParseError.malformed("call table outside LSDA") }
            let header = 0..<cursor
            let callEnd = cursor + Int(size)
            actionBegin = callEnd
            guard typeBase.map({ $0 >= callEnd }) ?? true else { throw ParseError.malformed("type base before actions") }
            try claim(header, kind: 1)
            var rawCalls: [(Range<UInt64>, UInt64?, UInt64, Range<Int>)] = []
            var previousEnd = functionStart
            while cursor < callEnd {
                guard rawCalls.count < 4096 else { throw ParseError.limit }
                let start = cursor
                var values: [UInt64] = []
                for _ in 0..<3 {
                    let value = try scalar(&cursor, end: callEnd, encoding: callEncoding)
                    guard callEncoding < 9 || Int64(bitPattern: value) >= 0 else {
                        throw ParseError.malformed("negative call-site scalar")
                    }
                    values.append(value)
                }
                let action = try leb(&cursor, end: callEnd)
                let lower = try add(functionStart, values[0])
                let upper = try add(lower, values[1])
                guard lower >= previousEnd, lower < functionEnd, upper <= functionEnd else {
                    throw ParseError.malformed("call-site range outside function or unsorted")
                }
                previousEnd = upper
                let landing = values[2] == 0 ? nil : try add(lpBase, values[2])
                if let landing {
                    guard landing >= functionStart, landing < functionEnd else {
                        throw ParseError.malformed("landing pad outside function")
                    }
                }
                try claim(start..<cursor, kind: 2)
                rawCalls.append((lower..<upper, landing, action, start..<cursor))
            }
            var calls: [CallSite] = []
            for (range, landing, rawAction, source) in rawCalls {
                var chain: [Int] = []
                if rawAction != 0 {
                    let initial = try add(UInt64(actionBegin), rawAction - 1)
                    guard initial < UInt64(end) else { throw ParseError.malformed("action offset outside LSDA") }
                    var next: Int? = Int(initial)
                    var seen = Set<Int>()
                    while let offset = next {
                        guard chain.count < 128 else { throw ParseError.limit }
                        guard seen.insert(offset).inserted else { throw ParseError.malformed("action cycle") }
                        chain.append(offset)
                        next = try readAction(offset).nextOffset
                    }
                }
                calls.append(CallSite(protectedRange: range, landingPad: landing,
                                      actionOffset: rawAction, actionChain: chain, source: source))
            }
            return Report(address: address, functionStart: functionStart, functionEnd: functionEnd,
                          landingPadBase: lpBase, headerSource: header, callsites: calls,
                          actions: actions.values.sorted { $0.offset < $1.offset },
                          types: types.values.sorted { $0.index < $1.index })
        }
    }
}

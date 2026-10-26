import Foundation

/// Portable alignment-independent reads for integration fixtures and transports.
/// The Python binary layer remains the production metadata schema authority.
public struct BinaryCursor: Sendable {
    private let bytes: [UInt8]
    public private(set) var offset: Int
    public let end: Int

    public init(data: Data, offset: Int = 0, count: Int? = nil, maximum: Int = 64 * 1024 * 1024) throws {
        guard data.count <= maximum, offset >= 0, offset <= data.count else {
            throw RecoveryError.invalid("binary cursor range")
        }
        let length = count ?? (data.count - offset)
        guard length >= 0, length <= data.count - offset else { throw RecoveryError.invalid("binary cursor count") }
        self.bytes = Array(data)
        self.offset = offset
        self.end = offset + length
    }

    public var remaining: Int { end - offset }

    public mutating func readBytes(_ count: Int) throws -> [UInt8] {
        guard count >= 0, count <= remaining else { throw RecoveryError.invalid("truncated binary field") }
        let value = Array(bytes[offset ..< offset + count])
        offset += count
        return value
    }

    public mutating func readUInt8() throws -> UInt8 { try readBytes(1)[0] }
    public mutating func readUInt16() throws -> UInt16 {
        let value = try readBytes(2)
        return UInt16(value[0]) | (UInt16(value[1]) << 8)
    }
    public mutating func readUInt32() throws -> UInt32 {
        let value = try readBytes(4)
        return value.enumerated().reduce(UInt32(0)) { $0 | (UInt32($1.element) << ($1.offset * 8)) }
    }
    public mutating func readInt32() throws -> Int32 { Int32(bitPattern: try readUInt32()) }
    public mutating func readUInt64() throws -> UInt64 {
        let value = try readBytes(8)
        return value.enumerated().reduce(UInt64(0)) { $0 | (UInt64($1.element) << ($1.offset * 8)) }
    }
    public mutating func readULEB128() throws -> UInt64 {
        var result: UInt64 = 0
        for index in 0 ..< 10 {
            let byte = try readUInt8()
            let payload = UInt64(byte & 0x7f)
            guard index < 9 || payload <= 1 else { throw RecoveryError.invalid("ULEB128 overflow") }
            result |= payload << (index * 7)
            if byte & 0x80 == 0 { return result }
        }
        throw RecoveryError.invalid("unterminated ULEB128")
    }
    public mutating func readCString(maximum: Int = 16_384) throws -> String {
        guard maximum > 0 else { throw RecoveryError.invalid("string limit") }
        var result: [UInt8] = []
        for _ in 0 ..< min(maximum, remaining) {
            let byte = try readUInt8()
            if byte == 0 {
                guard let text = String(bytes: result, encoding: .utf8) else { throw RecoveryError.invalid("invalid UTF-8") }
                return text
            }
            result.append(byte)
        }
        throw RecoveryError.invalid("unterminated bounded string")
    }
}

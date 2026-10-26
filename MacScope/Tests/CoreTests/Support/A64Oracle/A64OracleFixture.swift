import Foundation

/// One fixture of the A64 lifter oracle (`GoldenFixtures/a64-lifter-oracle/vectors.json.gz`,
/// schema `macscope-a64-lifter-oracle-1`). The file's `fixture_contract` is the authority; this
/// type mirrors only the fields the harness consumes.
struct A64OracleVector: Decodable, Sendable {
    struct MemoryRange: Decodable, Sendable {
        let address: String
        let bytes: String
    }

    /// Architectural state as the oracle writes it: hex strings, `NZCV` as a four-bit string.
    struct State: Decodable, Sendable {
        let gpr: [String: String]?
        let sp: String?
        let pc: String?
        let nzcv: String?
        let fpcr: String?
        let fpsr: String?
        let vectors: [String: String]?
        let memory: [MemoryRange]?

        enum CodingKeys: String, CodingKey {
            case gpr = "GPR", sp = "SP", pc = "PC", nzcv = "NZCV", fpcr = "FPCR", fpsr = "FPSR"
            case vectors = "Vn", memory
        }
    }

    let id: String
    let form: String
    let caseLabel: String
    let asm: String
    let category: String
    let word: String
    let inputs: State
    let expected: State

    enum CodingKeys: String, CodingKey {
        case id, form, asm, category, word, inputs, expected
        case caseLabel = "case"
    }

    var wordValue: UInt32? { A64OracleHex.uint64(word).flatMap { UInt32(exactly: $0) } }

    /// The family a report groups by: the form's leading mnemonic plus its category.
    var family: String {
        let mnemonic = form.split(separator: " ").first.map(String.init) ?? form
        return "\(category) / \(mnemonic)"
    }
}

struct A64OracleFile: Decodable, Sendable {
    let schema: String
    let repositoryRevision: String
    let vectors: [A64OracleVector]

    enum CodingKeys: String, CodingKey {
        case schema, vectors
        case repositoryRevision = "repository_revision"
    }

    static let fixtureDirectory = TestSourceRoot.fileURL(#filePath)
        .deletingLastPathComponent() // …/Support/A64Oracle
        .deletingLastPathComponent() // …/Support
        .deletingLastPathComponent() // …/CoreTests
        .appendingPathComponent("GoldenFixtures/a64-lifter-oracle", isDirectory: true)

    static func load(filename: String = "vectors.json.gz") throws -> A64OracleFile {
        let compressed = try Data(contentsOf: fixtureDirectory.appendingPathComponent(filename))
        return try JSONDecoder().decode(A64OracleFile.self, from: try A64OracleGzip.decompress(compressed))
    }
}

enum A64OracleHex {
    static func uint64(_ text: String) -> UInt64? {
        let trimmed = text.hasPrefix("0x") || text.hasPrefix("0X") ? String(text.dropFirst(2)) : text
        guard !trimmed.isEmpty, trimmed.count <= 16 else { return nil }
        return UInt64(trimmed, radix: 16)
    }

    /// A 128-bit value as (low, high) 64-bit halves.
    static func uint128(_ text: String) -> (low: UInt64, high: UInt64)? {
        var digits = text.hasPrefix("0x") || text.hasPrefix("0X") ? String(text.dropFirst(2)) : text
        guard !digits.isEmpty, digits.count <= 32 else { return nil }
        digits = String(repeating: "0", count: 32 - digits.count) + digits
        guard let high = UInt64(digits.prefix(16), radix: 16),
              let low = UInt64(digits.suffix(16), radix: 16) else { return nil }
        return (low, high)
    }

    static func bytes(_ text: String) -> [UInt8]? {
        guard text.count.isMultiple(of: 2) else { return nil }
        var result: [UInt8] = []
        result.reserveCapacity(text.count / 2)
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            guard let byte = UInt8(text[index..<next], radix: 16) else { return nil }
            result.append(byte)
            index = next
        }
        return result
    }

    static func format64(_ value: UInt64) -> String {
        let digits = String(value, radix: 16)
        return "0x" + String(repeating: "0", count: max(0, 16 - digits.count)) + digits
    }

    static func format128(low: UInt64, high: UInt64) -> String {
        "0x" + format64(high).dropFirst(2) + format64(low).dropFirst(2)
    }
}

/// gzip (RFC 1952) over Foundation's raw DEFLATE (`NSData.CompressionAlgorithm.zlib` is raw
/// RFC 1951). Only what `gzip -9 -n` writes is needed, but every optional header field is skipped.
enum A64OracleGzip {
    enum Failure: Error { case notGzip, truncated }

    static func decompress(_ data: Data) throws -> Data {
        let bytes = [UInt8](data)
        guard bytes.count >= 18, bytes[0] == 0x1f, bytes[1] == 0x8b, bytes[2] == 8 else { throw Failure.notGzip }
        let flags = bytes[3]
        var offset = 10
        if flags & 0x04 != 0 {
            guard offset + 2 <= bytes.count else { throw Failure.truncated }
            offset += 2 + Int(bytes[offset]) + Int(bytes[offset + 1]) << 8
        }
        for flag: UInt8 in [0x08, 0x10] where flags & flag != 0 {
            while offset < bytes.count, bytes[offset] != 0 { offset += 1 }
            offset += 1
        }
        if flags & 0x02 != 0 { offset += 2 }
        guard offset < bytes.count - 8 else { throw Failure.truncated }
        let deflate = Data(bytes[offset..<(bytes.count - 8)])
        return try (deflate as NSData).decompressed(using: .zlib) as Data
    }
}

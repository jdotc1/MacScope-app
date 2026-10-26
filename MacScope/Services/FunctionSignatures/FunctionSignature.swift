import Foundation

enum FunctionSignatureArchitecture: UInt8, Sendable, Hashable {
    case arm64 = 1
}

struct FunctionSignatureDatabase: Sendable, Hashable {
    static let currentSchemaVersion: UInt16 = 1

    let schemaVersion: UInt16
    let signatures: [FunctionSignature]
}

struct FunctionSignature: Sendable, Hashable {
    let architecture: FunctionSignatureArchitecture
    let name: String
    let libraryName: String
    let totalLength: UInt32
    let prefix: FunctionSignatureMaskedPattern
    let checksum: FunctionSignatureChecksumSpan
    let collisionTail: FunctionSignatureCollisionTail
}

struct FunctionSignatureMaskedPattern: Sendable, Hashable {
    let bytes: [UInt8]
    let comparisonMask: [UInt8]
}

struct FunctionSignatureChecksumSpan: Sendable, Hashable {
    let offset: UInt32
    let byteCount: UInt32
    let crc32: UInt32
}

struct FunctionSignatureCollisionTail: Sendable, Hashable {
    let byteRuns: [FunctionSignatureMaskedByteRun]
    let importedReferences: [FunctionSignatureImportedReference]
}

struct FunctionSignatureMaskedByteRun: Sendable, Hashable {
    let offset: UInt32
    let bytes: [UInt8]
    let comparisonMask: [UInt8]
}

struct FunctionSignatureImportedReference: Sendable, Hashable {
    let instructionOffset: UInt32
    let expectedSymbolName: String
}

/// CRC-32/ISO-HDLC as frozen by the WS-11 schema-v1 contract.
///
/// Parameters: reflected polynomial 0xEDB88320, initial value 0xFFFFFFFF,
/// reflected input/output, and final XOR 0xFFFFFFFF.
enum FunctionSignatureCRC32 {
    static func checksum(_ bytes: [UInt8]) -> UInt32 {
        var crc = UInt32.max
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                let lowBit = crc & 1
                crc >>= 1
                if lowBit != 0 {
                    crc ^= 0xEDB8_8320
                }
            }
        }
        return crc ^ UInt32.max
    }
}

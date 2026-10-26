import CryptoKit
import Foundation

enum ReconstructionCanonicalJSON {
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    static func sha256<T: Encodable>(of value: T) throws -> String {
        let digest = SHA256.hash(data: try encode(value))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

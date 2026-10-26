import Foundation

/// Shared disk representation for optional instruction operand metadata. The envelope's
/// schemaVersion is independent of the SQLite and MSINST container versions.
enum InstructionOperandsStorageCodec {
    static let maximumBytes = 1_048_576

    enum Failure: Error, Equatable, LocalizedError {
        case exceedsMaximumSize
        case unsupportedSchemaVersion(Int)

        var errorDescription: String? {
            switch self {
            case .exceedsMaximumSize: "The stored instruction operand metadata exceeds its size limit."
            case .unsupportedSchemaVersion(let version): "Unsupported instruction operand schema version \(version)."
            }
        }
    }

    static func encode(_ value: InstructionOperands) throws -> Data {
        guard value.schemaVersion == 1 else { throw Failure.unsupportedSchemaVersion(value.schemaVersion) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        guard data.count <= maximumBytes else { throw Failure.exceedsMaximumSize }
        return data
    }

    static func decode(_ data: Data) throws -> InstructionOperands {
        guard data.count <= maximumBytes else { throw Failure.exceedsMaximumSize }
        let value = try JSONDecoder().decode(InstructionOperands.self, from: data)
        guard value.schemaVersion == 1 else { throw Failure.unsupportedSchemaVersion(value.schemaVersion) }
        return value
    }
}

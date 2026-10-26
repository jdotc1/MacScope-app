import Foundation
import SQLite3

extension WorkspaceDatabase {
    /// The legacy IR blob is independent of the optional, versioned decoder operand facts.
    struct InstructionRecord: Equatable {
        var id: Int64?
        var functionID: Int64
        var address: UInt64
        var bytes: Data
        var mnemonic: String
        var operands: String
        var hasBreakpoint: Bool
        var comment: String?
        var irJSON: Data?
        var structuredOperands: InstructionOperands? = nil
    }

    func addInstructionOperandsColumnIfMissing() throws {
        if !Set(try columnNames(in: "instructions")).contains("structured_operands_json") {
            try execute("ALTER TABLE instructions ADD COLUMN structured_operands_json BLOB;")
        }
    }

    /// Do not silently accept a generated, non-nullable, or differently typed substitute column.
    func validateInstructionOperandsSchema() throws {
        let columns = try query("PRAGMA table_xinfo(instructions);") { statement -> (String, String, Int32, Int32, Int32) in
            guard let name = sqlite3_column_text(statement, 1), let type = sqlite3_column_text(statement, 2) else {
                throw DatabaseError.corruptRow(table: "instructions", rowIdentity: "schema", field: "structured_operands_json")
            }
            return (String(cString: name), String(cString: type).uppercased(),
                    sqlite3_column_int(statement, 3), sqlite3_column_int(statement, 5), sqlite3_column_int(statement, 6))
        }
        let matches = columns.filter { $0.0 == "structured_operands_json" }
        guard matches.count == 1, let column = matches.first,
              column.1 == "BLOB", column.2 == 0, column.3 == 0, column.4 == 0 else {
            throw DatabaseError.corruptRow(table: "instructions", rowIdentity: "schema", field: "structured_operands_json")
        }
    }

    static func instructionOperandsColumn(
        _ statement: OpaquePointer, payloadIndex: Int32, lengthIndex: Int32
    ) throws -> InstructionOperands? {
        let payloadType = sqlite3_column_type(statement, payloadIndex)
        if payloadType == SQLITE_NULL {
            guard sqlite3_column_type(statement, lengthIndex) == SQLITE_NULL else {
                throw invalidInstructionOperandsColumn(statement)
            }
            return nil
        }
        // Ask SQL for the blob's length first: reject wrong storage classes and excessive extents
        // before requesting a blob pointer or allocating a Data copy of an untrusted payload.
        guard payloadType == SQLITE_BLOB, sqlite3_column_type(statement, lengthIndex) == SQLITE_INTEGER else {
            throw invalidInstructionOperandsColumn(statement)
        }
        let byteCount = sqlite3_column_int64(statement, lengthIndex)
        guard byteCount > 0, byteCount <= Int64(InstructionOperandsStorageCodec.maximumBytes),
              Int64(sqlite3_column_bytes(statement, payloadIndex)) == byteCount,
              let bytes = sqlite3_column_blob(statement, payloadIndex) else {
            throw invalidInstructionOperandsColumn(statement)
        }
        return try InstructionOperandsStorageCodec.decode(Data(bytes: bytes, count: Int(byteCount)))
    }

    private static func invalidInstructionOperandsColumn(_ statement: OpaquePointer) -> DatabaseError {
        .corruptRow(table: "instructions", rowIdentity: String(sqlite3_column_int64(statement, 0)),
                    field: "structured_operands_json")
    }
}

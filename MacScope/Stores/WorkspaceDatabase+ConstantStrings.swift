import Foundation
import SQLite3

extension WorkspaceDatabase {
    /// Derived per-image facts, added idempotently like analysis fingerprints and no-return
    /// provenance. Legacy rows stay absent; no source bytes are reread on database open.
    static let constantCFStringsSchemaSQL = """
    CREATE TABLE IF NOT EXISTS constant_cfstrings (
      binary_id INTEGER NOT NULL REFERENCES binaries(id) ON DELETE CASCADE,
      address INTEGER NOT NULL,
      value_json TEXT NOT NULL,
      PRIMARY KEY (binary_id, address)
    );
    """

    func insertConstantCFStrings(_ map: [UInt64: MacIRConstantString], binaryID: Int64) throws {
        let entries = try ImageConstantStringProvider.validated(
            ImageConstantStringProvider.persistedCFStrings(in: map)
        )
        for entry in entries {
            try run("INSERT INTO constant_cfstrings (binary_id, address, value_json) VALUES (?, ?, ?);",
                    bindings: [.int64(binaryID), .address(entry.address), .text(String(decoding: try JSONEncoder().encode(entry.text), as: UTF8.self))])
        }
    }

    func constantCFStrings(binaryID: Int64) throws -> [UInt64: String] {
        let entries = try query(
            "SELECT address, value_json FROM constant_cfstrings WHERE binary_id = ? LIMIT ?;",
            bindings: [.int64(binaryID), .int64(Int64(ImageConstantStringProvider.maximumCFStringCount + 1))]
        ) { statement in
            ImageConstantStringProvider.PersistedCFString(
                address: try Self.addressColumn(statement, 0, field: "constant_cfstrings.address"),
                text: try JSONDecoder().decode(String.self, from: Data(Self.textColumn(statement, 1).utf8))
            )
        }
        return try ImageConstantStringProvider.validated(entries).reduce(into: [:]) { $0[$1.address] = $1.text }
    }

    @discardableResult
    func insertStringLiteral(_ record: StringLiteralRecord) throws -> StringLiteralRecord {
        try run(
            """
            INSERT INTO string_literals (uuid, binary_id, value, address, source_section, byte_length)
            VALUES (?, ?, ?, ?, ?, ?);
            """,
            bindings: [
                .text(record.uuid.uuidString),
                .int64(record.binaryID),
                .text(record.value),
                .address(record.address),
                .text(record.sourceSection),
                .int64(Int64(record.byteLength))
            ]
        )

        var inserted = record
        inserted.id = sqlite3_last_insert_rowid(try requireConnection())
        return inserted
    }

    func stringLiterals(binaryID: Int64) throws -> [StringLiteralRecord] {
        try query(
            """
            SELECT id, uuid, binary_id, value, address, source_section, byte_length
            FROM string_literals
            WHERE binary_id = ?
            ORDER BY id;
            """,
            bindings: [.int64(binaryID)],
            map: Self.stringLiteralRecord
        )
    }

    private static func stringLiteralRecord(from statement: OpaquePointer) throws -> StringLiteralRecord {
        let uuidString = try textColumn(statement, 1)
        guard let uuid = UUID(uuidString: uuidString) else {
            throw DatabaseError.invalidUUID(uuidString)
        }

        return StringLiteralRecord(
            id: sqlite3_column_int64(statement, 0),
            uuid: uuid,
            binaryID: sqlite3_column_int64(statement, 2),
            value: try textColumn(statement, 3),
            address: try addressColumn(statement, 4, field: "string_literals.address"),
            sourceSection: try textColumn(statement, 5),
            byteLength: Int(sqlite3_column_int64(statement, 6))
        )
    }

}

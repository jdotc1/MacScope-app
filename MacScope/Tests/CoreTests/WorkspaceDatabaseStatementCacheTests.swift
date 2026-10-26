import Foundation
import SQLite3
import XCTest
@testable import MacScope

/// C8: `WorkspaceDatabase.run` reuses one prepared statement per SQL text, so a save's per-row
/// INSERTs no longer re-enter SQLite's parser for every instruction. Reuse must be invisible.
final class WorkspaceDatabaseStatementCacheTests: XCTestCase {
    func testReusedInsertKeepsRowsBindingsAndRowIDsAfterAFailure() throws {
        let database = try WorkspaceDatabase.inMemory()
        try database.run("CREATE TABLE cache_probe (id INTEGER PRIMARY KEY, value TEXT NOT NULL UNIQUE, note TEXT);")
        let insert = "INSERT INTO cache_probe (value, note) VALUES (?, ?);"
        for index in 0..<500 {
            try database.run(insert, bindings: [.text("v\(index)"), index.isMultiple(of: 2) ? .text("even") : .null])
        }
        // A constraint failure leaves the cached statement reusable, with no stale bindings.
        XCTAssertThrowsError(try database.run(insert, bindings: [.text("v7"), .text("duplicate")]))
        try database.run(insert, bindings: [.text("after-failure"), .null])

        let rows = try database.query("SELECT id, value, note FROM cache_probe ORDER BY id;", map: { statement in
            (Int(sqlite3_column_int64(statement, 0)),
             String(cString: sqlite3_column_text(statement, 1)),
             sqlite3_column_type(statement, 2) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(statement, 2)))
        })
        XCTAssertEqual(rows.count, 501)
        XCTAssertEqual(rows.map(\.0), Array(1...501))
        XCTAssertEqual(rows[2].1, "v2")
        XCTAssertEqual(rows[2].2, "even")
        XCTAssertNil(rows[3].2, "a null binding is not inherited from the previous row")
        XCTAssertEqual(rows.last?.1, "after-failure")
        XCTAssertNil(rows.last?.2)
    }

    func testCachedStatementsDoNotHoldTheSchema() throws {
        let database = try WorkspaceDatabase.inMemory()
        try database.run("CREATE TABLE dropped_probe (value INTEGER);")
        try database.run("INSERT INTO dropped_probe (value) VALUES (?);", bindings: [.int64(1)])
        // A reset statement is not active, so the table it names can still be dropped.
        try database.run("DROP TABLE dropped_probe;")
        try database.run("CREATE TABLE dropped_probe (value INTEGER, extra INTEGER);")
        try database.run("INSERT INTO dropped_probe (value) VALUES (?);", bindings: [.int64(2)])
        XCTAssertEqual(try database.query("SELECT value FROM dropped_probe;", map: { sqlite3_column_int64($0, 0) }), [2])
    }
}

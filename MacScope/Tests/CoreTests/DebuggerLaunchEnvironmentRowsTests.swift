import Foundation
import LumenUI
import XCTest
@testable import MacScope

/// U9-4b: the launch environment on `LumenKeyValueEditor` maps back to the view model's entries
/// without inventing an override: Lumen's + names a new row "key1", which must stay blank (and
/// so ignored at launch) until the user types.
final class DebuggerLaunchEnvironmentRowsTests: XCTestCase {
    func testAFreshAutoNamedRowComesBackBlankAndEditsAreKept() {
        let existing = DebuggerEnvironmentEntry(key: "DYLD_PRINT_LIBRARIES", value: "1")
        let fresh = LumenKeyValue(key: "key1", value: "") // what Lumen's + names a first new row
        let entries = DebuggerLaunchEnvironmentRows.entries(
            from: [LumenKeyValue(key: existing.key, value: existing.value, id: existing.id), fresh],
            known: [existing.id]
        )
        XCTAssertEqual(entries.map(\.key), ["DYLD_PRINT_LIBRARIES", ""])
        XCTAssertEqual(entries.map(\.id), [existing.id, fresh.id])
        XCTAssertTrue(entries[1].isBlank, "an untouched new row launches nothing")
    }

    func testOnlyUntouchedNewRowsAreBlanked() {
        let typedValue = LumenKeyValue(key: "key1", value: "on")
        let userNamedKey1 = DebuggerEnvironmentEntry(key: "key1", value: "")
        let entries = DebuggerLaunchEnvironmentRows.entries(
            from: [typedValue, LumenKeyValue(key: "key1", value: "", id: userNamedKey1.id),
                   LumenKeyValue(key: "MY_KEY", value: "")],
            known: [userNamedKey1.id]
        )
        XCTAssertEqual(entries.map(\.key), ["key1", "key1", "MY_KEY"], "a value, a known row, or a real name keeps the key")
    }

    func testRemovingEveryRowLeavesOneBlankRow() {
        let entries = DebuggerLaunchEnvironmentRows.entries(from: [], known: [UUID()])
        XCTAssertEqual(entries.count, 1)
        XCTAssertTrue(entries[0].isBlank)
    }
}

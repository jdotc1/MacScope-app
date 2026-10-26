import Foundation
import XCTest
@testable import MacScope

/// `WorkspaceSnapshot.sourceLine(at:)` maps an instruction address to the covering DWARF line-table
/// row (greatest row address ≤ target), and returns nil in a gap (past an `endSequence` terminator)
/// or before the first row — the lookup that drives the inspector + listing gutter surfaces.
final class SourceLineLookupTests: XCTestCase {

    private func snapshot(_ rows: [SourceLineEntry]) -> WorkspaceSnapshot {
        WorkspaceSnapshot(binaries: [], functions: [], instructions: [], xrefs: [], hexBytes: Data(),
                          sourceLines: rows)
    }

    func testLookupReturnsNearestPrecedingRowAndNilInGaps() {
        let snap = snapshot([
            SourceLineEntry(address: 0x100, file: "a.c", line: 10, column: 1, endSequence: false),
            SourceLineEntry(address: 0x108, file: "a.c", line: 11, column: 5, endSequence: false),
            SourceLineEntry(address: 0x110, file: nil, line: 0, column: 0, endSequence: true),
            SourceLineEntry(address: 0x200, file: "a.c", line: 20, column: 1, endSequence: false),
            SourceLineEntry(address: 0x208, file: nil, line: 0, column: 0, endSequence: true),
        ])
        XCTAssertEqual(snap.sourceLine(at: 0x100)?.line, 10, "exact start of a row")
        XCTAssertEqual(snap.sourceLine(at: 0x104)?.line, 10, "between rows resolves to the preceding row")
        XCTAssertEqual(snap.sourceLine(at: 0x108)?.line, 11)
        XCTAssertEqual(snap.sourceLine(at: 0x10C)?.line, 11, "still within the second row's coverage")
        XCTAssertNil(snap.sourceLine(at: 0x110), "at an endSequence terminator → gap, no line")
        XCTAssertNil(snap.sourceLine(at: 0x180), "between sequences → gap")
        XCTAssertEqual(snap.sourceLine(at: 0x204)?.line, 20, "covered by the second sequence")
        XCTAssertNil(snap.sourceLine(at: 0x208), "past the final terminator → no line")
        XCTAssertNil(snap.sourceLine(at: 0x50), "before the first row → nil")
        XCTAssertNil(snapshot([]).sourceLine(at: 0x100), "no dSYM imported → nil")
    }
}

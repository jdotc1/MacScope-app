import XCTest
@testable import MacScope

/// U3a: the register grid marks registers that changed since the previous snapshot.
final class DebuggerRegisterChangeTests: XCTestCase {
    private func regs(_ pairs: [(String, String)]) -> [DebuggerRegisterSummary] {
        pairs.map { DebuggerRegisterSummary(name: $0.0, value: $0.1) }
    }

    func testChangedValuesAreMarkedAndNewOrSameOnesAreNot() {
        let changed = DebuggerPanelViewModel.changedRegisterNames(
            previous: regs([("x0", "0x1"), ("x1", "0x2"), ("pc", "0x100")]),
            next: regs([("x0", "0x1"), ("x1", "0x3"), ("pc", "0x104"), ("x2", "0x9")])
        )
        XCTAssertEqual(changed, ["x1", "pc"])
    }

    func testIdenticalRegisterSetsKeepTheCurrentMarks() {
        let same = regs([("x0", "0x1")])
        XCTAssertNil(DebuggerPanelViewModel.changedRegisterNames(previous: same, next: same))
    }

    func testNoRegistersClearsTheMarks() {
        XCTAssertEqual(DebuggerPanelViewModel.changedRegisterNames(previous: regs([("x0", "0x1")]), next: []), [])
    }

    func testFirstSnapshotMarksNothing() {
        XCTAssertEqual(DebuggerPanelViewModel.changedRegisterNames(previous: [], next: regs([("x0", "0x1")])), [])
    }
}

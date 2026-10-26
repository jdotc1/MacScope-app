import XCTest

@testable import MacScope

final class Phase2ShellInputHistoryTests: XCTestCase {
    func testHistoryCommitsTrimmedUniqueCommandsInSubmissionOrder() {
        var history = Phase2ShellInputHistory()

        history.commit("  pwd  ")
        history.commit("ls -la")
        history.commit("pwd")

        XCTAssertEqual(history.entries, ["ls -la", "pwd"])
        XCTAssertTrue(history.canNavigatePrevious)
        XCTAssertFalse(history.canNavigateNext)
    }

    func testHistoryNavigationRestoresDraftAfterNewestEntry() throws {
        var history = Phase2ShellInputHistory(entries: ["pwd", "git status"])

        XCTAssertEqual(history.previous(currentDraft: "draft"), "git status")
        XCTAssertEqual(history.previous(currentDraft: "ignored"), "pwd")
        XCTAssertFalse(history.canNavigatePrevious)
        XCTAssertEqual(history.next(), "git status")
        XCTAssertEqual(history.next(), "draft")
        XCTAssertFalse(history.canNavigateNext)
    }

    func testHistoryBoundsEntryCountAndIgnoresBlankInput() {
        var history = Phase2ShellInputHistory(maximumEntries: 3)

        history.commit("one")
        history.commit("two")
        history.commit("three")
        history.commit("four")
        history.commit("   ")

        XCTAssertEqual(history.entries, ["two", "three", "four"])
    }

    func testResetNavigationClearsCursorWithoutDeletingEntries() {
        var history = Phase2ShellInputHistory(entries: ["one", "two"])
        XCTAssertEqual(history.previous(currentDraft: ""), "two")

        history.resetNavigation()

        XCTAssertNil(history.cursor)
        XCTAssertEqual(history.entries, ["one", "two"])
        XCTAssertTrue(history.canNavigatePrevious)
        XCTAssertFalse(history.canNavigateNext)
    }
}

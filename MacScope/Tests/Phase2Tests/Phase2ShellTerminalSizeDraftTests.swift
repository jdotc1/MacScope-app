import XCTest

@testable import MacScope

final class Phase2ShellTerminalSizeDraftTests: XCTestCase {
    func testTerminalSizeDraftParsesTrimmedWholeNumberColumnsAndRows() {
        let draft = Phase2ShellTerminalSizeDraft(columnsText: " 132 ", rowsText: "\n44 ")

        XCTAssertEqual(draft.normalizedTerminalSize, Phase2HumanPTYTerminalSize(columns: 132, rows: 44))
        XCTAssertNil(draft.terminalSizeValidationMessage)
    }

    func testRestoredTerminalSizeFormatsBackIntoEditableDraft() {
        let draft = Phase2ShellTerminalSizeDraft(
            restoredTerminalSize: Phase2HumanPTYTerminalSize(columns: 132, rows: 44)
        )

        XCTAssertEqual(draft.columnsText, "132")
        XCTAssertEqual(draft.rowsText, "44")
        XCTAssertEqual(draft.normalizedTerminalSize, Phase2HumanPTYTerminalSize(columns: 132, rows: 44))
        XCTAssertNil(draft.terminalSizeValidationMessage)
    }

    func testTerminalSizeDraftRejectsBlankNonNumericAndOutOfRangeValues() {
        XCTAssertEqual(
            Phase2ShellTerminalSizeDraft(columnsText: "", rowsText: "32").terminalSizeValidationMessage,
            "Terminal size requires columns and rows."
        )
        XCTAssertEqual(
            Phase2ShellTerminalSizeDraft(columnsText: "120.5", rowsText: "32").terminalSizeValidationMessage,
            "Terminal size must use whole-number columns and rows."
        )
        XCTAssertEqual(
            Phase2ShellTerminalSizeDraft(columnsText: "0", rowsText: "32").terminalSizeValidationMessage,
            "Terminal size must be between 1×1 and 1000×1000."
        )
        XCTAssertEqual(
            Phase2ShellTerminalSizeDraft(columnsText: "120", rowsText: "1001").terminalSizeValidationMessage,
            "Terminal size must be between 1×1 and 1000×1000."
        )
    }
}

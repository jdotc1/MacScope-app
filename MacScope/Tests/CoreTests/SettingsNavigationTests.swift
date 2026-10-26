import XCTest
@testable import MacScope

final class SettingsNavigationTests: XCTestCase {
    func testHistoryNavigatesBackAndForwardLikeSystemSettings() {
        var history = SettingsHistory<SettingsCategory>()
        history.visit(from: .analysis, to: .appearance)
        history.visit(from: .appearance, to: .debugger)
        XCTAssertTrue(history.canGoBack)
        XCTAssertFalse(history.canGoForward)

        XCTAssertEqual(history.goBack(from: .debugger), .appearance)
        XCTAssertEqual(history.goBack(from: .appearance), .analysis)
        XCTAssertNil(history.goBack(from: .analysis))
        XCTAssertEqual(history.goForward(from: .analysis), .appearance)

        history.visit(from: .appearance, to: .plugins)
        XCTAssertFalse(history.canGoForward, "A new visit clears the forward stack")
        history.visit(from: .plugins, to: .plugins)
        XCTAssertEqual(history.backStack.last, .appearance, "Re-selecting the current page is not a visit")
    }

    func testSearchFindsCategoriesByTheSettingsTheyContain() {
        XCTAssertEqual(SettingsCategory.matching(""), SettingsCategory.allCases)
        XCTAssertEqual(SettingsCategory.matching("utf-16"), [.keysAndDisplay])
        XCTAssertEqual(SettingsCategory.matching("MIDNIGHT"), [.appearance])
        XCTAssertEqual(SettingsCategory.matching("stop entry"), [.debugger])
        XCTAssertEqual(SettingsCategory.matching("mtplx"), [.localAI])
        XCTAssertTrue(SettingsCategory.matching("lm studio").isEmpty)
        XCTAssertTrue(SettingsCategory.matching("default decompiler").isEmpty)
        XCTAssertTrue(SettingsCategory.matching("cpu sub-mode").isEmpty)
        XCTAssertTrue(SettingsCategory.matching("thumb").isEmpty)
        XCTAssertTrue(SettingsCategory.matching("zzz").isEmpty)
    }

    func testEveryCategoryIsFindableByItsOwnTitle() {
        for category in SettingsCategory.allCases {
            XCTAssertTrue(SettingsCategory.matching(category.title).contains(category), category.title)
        }
    }
}

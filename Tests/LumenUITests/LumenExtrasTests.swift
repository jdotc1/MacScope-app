import XCTest
@testable import LumenUI

@MainActor
final class LumenExtrasTests: XCTestCase {
    private let nodes = [
        LumenChecklistNode(id: "src", title: "Sources", depth: 0),
        LumenChecklistNode(id: "a", title: "a.swift", depth: 1),
        LumenChecklistNode(id: "b", title: "b.swift", depth: 1),
        LumenChecklistNode(id: "readme", title: "README.md", depth: 0),
    ]

    func testFolderStateFollowsItsFiles() {
        XCTAssertEqual(LumenChecklistTree.leaves(under: 0, in: nodes), ["a", "b"])
        XCTAssertEqual(LumenChecklistTree.leaves(under: 3, in: nodes), ["readme"])
        XCTAssertEqual(LumenChecklistTree.state(of: 0, in: nodes, checked: ["a"]), .mixed)
        XCTAssertEqual(LumenChecklistTree.state(of: 0, in: nodes, checked: ["a", "b"]), .on)
        XCTAssertEqual(LumenChecklistTree.state(of: 0, in: nodes, checked: []), .off)
    }

    func testComposerCountsTheFirstLine() {
        XCTAssertEqual(LumenCommitComposer.summaryLength("Fix the thing\n\nLonger body here"), 13)
        XCTAssertEqual(LumenCommitComposer.summaryLength(""), 0)
    }

    func testScopeChipLabelsCarryCounts() {
        XCTAssertEqual(LumenFilterChips<String>.label("Conflicts", count: 2), "Conflicts (2)")
        XCTAssertEqual(LumenFilterChips<String>.label("All", count: nil), "All")
    }

    func testFontStylesFallBackToRegular() {
        XCTAssertEqual(LumenFontPicker.styles(of: "No Such Family 123"), ["Regular"])
        XCTAssertTrue(LumenFontPicker.styles(of: "Menlo").contains("Bold"))
    }
}

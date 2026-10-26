import XCTest
@testable import MacScope

final class NavigatorToolLayoutTests: XCTestCase {
    func testDefaultLayoutShowsEveryToolInDeclarationOrder() {
        let layout = NavigatorToolLayout(encoded: "", all: WorkspaceTool.allCases)
        XCTAssertTrue(layout.isDefault)
        XCTAssertEqual(layout.visible, WorkspaceTool.allCases)
        XCTAssertEqual(layout.encoded, "")
    }

    func testReorderHideAndRoundTrip() {
        var layout = NavigatorToolLayout(all: WorkspaceTool.allCases)
        layout.move(.symbols, by: -1)
        XCTAssertEqual(layout.visible.prefix(2), [.symbols, .project])
        XCTAssertFalse(layout.canMove(.symbols, by: -1))
        XCTAssertTrue(layout.hide(.strings))
        XCTAssertFalse(layout.visible.contains(.strings))

        let restored = NavigatorToolLayout(encoded: layout.encoded, all: WorkspaceTool.allCases)
        XCTAssertEqual(restored, layout)
    }

    func testUnknownEntriesAreDroppedAndNewToolsAppear() {
        let layout = NavigatorToolLayout(encoded: "Debug,NoSuchTool,-Project,Debug", all: WorkspaceTool.allCases)
        XCTAssertEqual(layout.order.first, .debug)
        XCTAssertEqual(Set(layout.order), Set(WorkspaceTool.allCases))
        XCTAssertEqual(layout.hidden, [.project])
    }

    func testTheLastVisibleToolCannotBeHidden() {
        let allHidden = WorkspaceTool.allCases.map { "-" + $0.rawValue }.joined(separator: ",")
        var layout = NavigatorToolLayout(encoded: allHidden, all: WorkspaceTool.allCases)
        XCTAssertEqual(layout.visible, WorkspaceTool.allCases, "A stored all-hidden layout falls back to showing everything")
        for tool in WorkspaceTool.allCases.dropFirst() { layout.hide(tool) }
        XCTAssertFalse(layout.hide(WorkspaceTool.allCases[0]))
        XCTAssertEqual(layout.visible.count, 1)
        layout.reset()
        XCTAssertTrue(layout.isDefault)
    }
}

import SwiftUI
import XCTest
@testable import LumenUI

@MainActor
final class LumenToolsTests: XCTestCase {
    func testDockingAPaneShowsAndPlacesIt() {
        var layout = LumenToolLayout(all: ["files", "find", "git", "debug"])
        _ = layout.hide("debug")
        layout.dock("debug", before: "find")
        XCTAssertEqual(layout.visible, ["files", "debug", "find", "git"])
        layout.dock("files", before: nil)
        XCTAssertEqual(layout.visible, ["debug", "find", "git", "files"])
        layout.dock("nope", before: nil)
        XCTAssertEqual(layout.visible.count, 4, "Unknown panes are ignored")
    }

    func testRecorderNeedsAPrimaryModifierExceptForFunctionKeys() {
        XCTAssertNil(LumenShortcutRecorder.shortcut(for: "a", modifiers: []))
        XCTAssertNil(LumenShortcutRecorder.shortcut(for: "a", modifiers: .shift))
        XCTAssertEqual(LumenShortcutRecorder.shortcut(for: "k", modifiers: [.command, .shift]), KeyboardShortcut("k", modifiers: [.command, .shift]))
        let f5 = KeyEquivalent(Character(UnicodeScalar(0xF708)!))
        XCTAssertNotNil(LumenShortcutRecorder.shortcut(for: f5, modifiers: []))
    }

    func testCollectionSortsAndGroups() {
        let now = Date()
        let items = [
            LumenCollectionItem(id: "b", title: "beta", detail: "~/b", date: now.addingTimeInterval(-60), group: "Work"),
            LumenCollectionItem(id: "a", title: "Alpha", detail: "~/z", date: now, group: nil),
            LumenCollectionItem(id: "c", title: "gamma", detail: "~/a", date: nil, group: "Work"),
        ]
        XCTAssertEqual(LumenCollection.sorted(items, by: .title).map(\.id), ["a", "b", "c"])
        XCTAssertEqual(LumenCollection.sorted(items, by: .detail).map(\.id), ["c", "b", "a"])
        XCTAssertEqual(LumenCollection.sorted(items, by: .date).map(\.id), ["a", "b", "c"])
        XCTAssertEqual(LumenCollection.grouped(items).map(\.0), ["", "Work"])
    }
}

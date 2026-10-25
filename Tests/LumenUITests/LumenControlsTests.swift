import XCTest
import SwiftUI
import LumenTokens
@testable import LumenUI

@MainActor final class LumenControlsTests: XCTestCase {
    private struct Item: Identifiable { let id: Int; let name: String }

    private func renders<V: View>(_ view: V, _ size: CGSize) -> Bool {
        let variant = LumenSnapshot.Variant.all(for: LumenRegistry.core.galleryThemes)[0]
        return LumenSnapshot.png(of: view, size: size, variant: variant, registry: .core) != nil
    }

    /// R6 Components #3: a sidebar keeps its own text in an inactive window, so its quiet selection
    /// is its own role, `sidebar.rowSelectedInactive`, validated against that text. Slate Sidebar's
    /// light text on Standard light's gray inactive fill was 1.13:1.
    func testInactiveSidebarSelectionStaysOnTheSidebarsOwnGround() throws {
        let slate = try LumenThemeLibrary.decodeTheme(Data(contentsOf: TestPack.darkSidebarURL)).flattened { TestPack.registry.theme(id: $0) }
        let store = TestPack.store(themes: TestPack.registry.galleryThemes + [slate])
        func fill(_ state: LumenRowState, _ context: LumenRowContext = .sidebar) -> NSColor {
            NSColor(LumenRowColors(state, context: context, palette: store.resolvedPalette()).fill)
        }
        store.select(slate.id)
        XCTAssertEqual(try hex(fill(.selectedInactive), in: .aqua), "#353A45", "Slate sets its own inactive selection")
        XCTAssertEqual(try hex(fill(.selectedInactive), in: .darkAqua), "#2D2B40", "Slate's dark variant doesn't theme the sidebar")
        XCTAssertEqual(try hex(fill(.selectedInactive, .content), in: .aqua), "#E2E0E9", "Content rows go quiet as before")
        store.select(LumenThemes.standardID)
        XCTAssertEqual(try hex(fill(.selectedInactive), in: .aqua), "#DAD6E8", "Standard light sets a sidebar inactive selection a step deeper than hover")
        XCTAssertEqual(try hex(fill(.selected), in: .aqua), "#E4DFFF")
        // On a card the role follows bg.selectedInactive's raised value.
        store.select(LumenThemes.standardID)
        let raised = store.resolvedPalette().raised()
        XCTAssertEqual(try hex(NSColor(LumenRowColors(.selectedInactive, context: .sidebar, palette: raised).fill), in: .darkAqua), "#363449")
    }

    /// R6 Components #4: a click or Tab into an empty filter field is never mistaken for AppKit's
    /// initial focus grant; the grant (no event, or the event that opened the window) still is.
    func testFilterFieldTellsADeliberateFocusFromTheInitialGrant() {
        let window = NSWindow(), opener = NSWindow()
        XCTAssertTrue(LumenFilterField.isDeliberateFocus((.leftMouseDown, window), keyWindow: window), "A click in the field")
        XCTAssertTrue(LumenFilterField.isDeliberateFocus((.keyDown, window), keyWindow: window), "Tab into the field")
        XCTAssertFalse(LumenFilterField.isDeliberateFocus(nil, keyWindow: window), "A grant with no event")
        XCTAssertFalse(LumenFilterField.isDeliberateFocus((.keyDown, opener), keyWindow: window), "⌘N in the window before")
        XCTAssertFalse(LumenFilterField.isDeliberateFocus((.leftMouseDown, nil), keyWindow: window), "A menu click")
        XCTAssertFalse(LumenFilterField.isDeliberateFocus((.appKitDefined, window), keyWindow: window), "Window activation")
    }

    func testTextColumnReadsItsValue() {
        let column = LumenTableColumn<Item>.text("Name", width: 80, monospaced: true) { $0.name }
        XCTAssertEqual(column.id, "Name")
        XCTAssertEqual(column.width, 80)
    }

    func testFooterOffersOnlyWhatItIsGiven() {
        let footer = LumenTableFooter(onAdd: {})
        XCTAssertNotNil(footer.onAdd)
        XCTAssertNil(footer.onRemove)
        XCTAssertNil(footer.onEdit)
        XCTAssertNil(footer.trailing)
    }

    func testHeaderStyleAndPlainRadiosRender() {
        XCTAssertTrue(renders(LumenTabbedBox(selection: .constant(1), tabs: [1, 2], style: .header, title: { "Tab \($0)" }) { _ in Text("Body") },
                              CGSize(width: 320, height: 160)))
        XCTAssertTrue(renders(LumenRadioGroup(selection: .constant("A"), options: ["A", "B"], title: { $0 }), CGSize(width: 200, height: 80)))
        XCTAssertTrue(renders(LumenTable([Item(id: 1, name: "HOME")], selection: .constant(nil), columns: [.text("Key") { $0.name }]),
                              CGSize(width: 300, height: 160)))
    }
}

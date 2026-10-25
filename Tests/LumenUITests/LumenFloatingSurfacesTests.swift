import AppKit
import SwiftUI
import XCTest
@testable import LumenUI

/// Floating surfaces and lists (command menu, keycaps, shortcut recorder, address
/// field).
@MainActor
final class LumenFloatingSurfacesTests: XCTestCase {
    // MARK: Command menu ids (CODE-40)

    func testSeparatorIDsAreStableAcrossBuilds() {
        // A menu built in a `body` must not change its ids on every parent update.
        XCTAssertEqual(LumenMenuEntry.separator().id, LumenMenuEntry.separator().id)
        XCTAssertEqual(LumenMenuEntry.separator("a").id, "separator:a")
    }

    func testItemsWithOneTitleCanTakeDistinctIDs() {
        let first = LumenMenuEntry.item(id: "file.open", "Open")
        let second = LumenMenuEntry.item(id: "project.open", "Open")
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(LumenMenuEntry.item("Open").id, "item:Open", "The title stays the default id")
        XCTAssertNotEqual(LumenMenuEntry.submenu(id: "a", "Recent", []).id, LumenMenuEntry.submenu(id: "b", "Recent", []).id)
    }

    // MARK: Command menu icon column (A-16)

    func testAnIconAnywhereInAListKeepsTheIconColumn() {
        XCTAssertTrue(LumenCommandMenu.hasIcons([.item("Calculator", systemImage: "app"), .separator(), .item("Clear Menu")]))
        XCTAssertFalse(LumenCommandMenu.hasIcons([.item("Cut"), .item("Copy")]))
    }

    // MARK: Keycaps (A-18, B33, B35)

    func testHighGlyphsAreLoweredToTheCapsMiddle() {
        XCTAssertGreaterThan(LumenKeycap.opticalDrop(for: "↩"), 0)
        XCTAssertGreaterThan(LumenKeycap.opticalDrop(for: "⌃"), 0)
        XCTAssertEqual(LumenKeycap.opticalDrop(for: "K"), 0)
        XCTAssertEqual(LumenKeycap.opticalDrop(for: "esc"), 0)
    }

    func testWordAndGlyphKeysShareOneHeight() {
        let glyph = NSHostingView(rootView: LumenKeycap(["⌘"]).fixedSize()).fittingSize
        let word = NSHostingView(rootView: LumenKeycap(["Space"]).fixedSize()).fittingSize
        XCTAssertEqual(glyph.height, LumenKeycap.height, accuracy: 0.5)
        XCTAssertEqual(word.height, LumenKeycap.height, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(glyph.width, LumenKeycap.height - 0.5, "One-glyph keys are at least square")
    }

    // MARK: Shortcut recorder (CODE-58)

    private func keyDown(_ characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0,
                                       context: nil, characters: characters, charactersIgnoringModifiers: characters,
                                       isARepeat: false, keyCode: keyCode))
    }

    func testRecorderRecordsMenuOwnedKeyEquivalents() throws {
        // ⌘N goes to the main menu before keyDown; the local monitor sees it first.
        XCTAssertEqual(LumenShortcutRecorder.recorderAction(for: try keyDown("n", keyCode: 45, modifiers: .command)),
                       .record(KeyboardShortcut("n", modifiers: .command)))
        XCTAssertEqual(LumenShortcutRecorder.recorderAction(for: try keyDown("s", keyCode: 1, modifiers: [.command, .shift])),
                       .record(KeyboardShortcut("s", modifiers: [.command, .shift])))
    }

    func testRecorderEscapeCancelsDeleteClearsPlainLettersAreIgnored() throws {
        XCTAssertEqual(LumenShortcutRecorder.recorderAction(for: try keyDown("\u{1B}", keyCode: 53)), .cancel)
        XCTAssertEqual(LumenShortcutRecorder.recorderAction(for: try keyDown("\u{7F}", keyCode: 51)), .clear)
        XCTAssertEqual(LumenShortcutRecorder.recorderAction(for: try keyDown("a", keyCode: 0)), .ignore)
        XCTAssertEqual(LumenShortcutRecorder.recorderAction(for: try keyDown("\u{7F}", keyCode: 51, modifiers: .command)),
                       .record(KeyboardShortcut(.delete, modifiers: .command)), "⌘⌫ is a shortcut, not Clear")
    }

    // MARK: Address field (L13)

    func testAProgrammatic0xValueShowsOnePrefix() {
        XCTAssertEqual(LumenAddressField.sanitize("0x00000001000FFFFF"), "00000001000FFFFF")
        XCTAssertEqual(LumenAddressField.sanitize("0X1f"), "1f")
        XCTAssertEqual(LumenAddressField.sanitize("0x0x10"), "010", "Only one leading prefix is dropped; the rest is filtered")
    }
}

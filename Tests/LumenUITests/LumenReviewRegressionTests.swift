import AppKit
import SwiftUI
import XCTest
import LumenTokens
@testable import LumenUI

/// Regression tests for layout, theme and accessibility fixes.
@MainActor
final class LumenReviewRegressionTests: XCTestCase {
    private func command(_ title: String, id: String? = nil, category: String = "View") -> LumenCommand {
        LumenCommand(id: id, title, category: category, systemImage: "circle") {}
    }

    func testMatcherFindsTheBestPlacementNotTheFirst() {
        XCTAssertEqual(LumenCommandMatcher.match("pan", title: "Open Panel")?.offsets, [5, 6, 7])
        let rows = LumenCommandMatcher.rows([command("Span Selection"), command("Open Panel")], query: "pan", recents: [])
        XCTAssertEqual(rows.first?.command.title, "Open Panel")
    }

    func testMatcherIgnoresAccentsAndKeepsOffsetsInTheTitle() {
        XCTAssertEqual(LumenCommandMatcher.match("cafe", title: "Open Café")?.offsets, [5, 6, 7, 8])
        XCTAssertEqual(LumenCommandMatcher.match("café", title: "Open Cafe")?.offsets, [5, 6, 7, 8])
    }

    func testDuplicateCommandIDsKeepTheFirst() {
        let rows = LumenCommandMatcher.rows([command("Open", id: "x"), command("Close", id: "x")], query: "", recents: [])
        XCTAssertEqual(rows.map(\.command.title), ["Open"])
    }

    func testRecentsDropCommandsThatAreGone() throws {
        let suite = "lumen.review.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let recents = LumenCommandRecents(key: "r", defaults: defaults)
        recents.record("old")
        recents.record("a")
        recents.record("b", among: ["a", "b"])
        XCTAssertEqual(recents.ids, ["b", "a"])
    }

    func testKeycapsNameEveryKeyReadably() {
        XCTAssertEqual(LumenKeycap.name(of: .home), "↖")
        XCTAssertEqual(LumenKeycap.name(of: .pageDown), "⇟")
        XCTAssertEqual(LumenKeycap.name(of: .deleteForward), "⌦")
        XCTAssertEqual(LumenKeycap.name(of: KeyEquivalent(Character(UnicodeScalar(0xF704)!))), "F1")
        XCTAssertEqual(LumenKeycap.name(of: KeyEquivalent(Character(UnicodeScalar(0xF70F)!))), "F12")
        XCTAssertEqual(LumenKeycap.text(for: KeyboardShortcut("k", modifiers: [.command, .shift])), "⇧⌘K")
    }

    func testGridRowStepsStayPutAtTheEdges() {
        let ids = Array(0..<10)
        XCTAssertEqual(LumenSelectionStep.next(ids, from: 2, by: -5, staysInRange: true), 2, "↑ from the top row")
        XCTAssertEqual(LumenSelectionStep.next(ids, from: 7, by: 5, staysInRange: true), 7, "↓ from the bottom row")
        XCTAssertEqual(LumenSelectionStep.next(ids, from: 2, by: 5, staysInRange: true), 7)
        XCTAssertEqual(LumenSelectionStep.next(ids, from: 9, by: 1), 9, "→ still stops at the end")
    }

    func testAPanelToggleWithoutAShortcutHasNone() {
        var shortcuts = LumenViewShortcuts.standard
        shortcuts.panel = nil
        let toggle = LumenPanelToggle(edge: .bottom, isOn: .constant(true), shortcut: shortcuts.shortcut(for: .bottom))
        XCTAssertNil(Mirror(reflecting: toggle).descendant("shortcut") as? KeyboardShortcut)
        let standard = LumenPanelToggle(edge: .bottom, isOn: .constant(true))
        XCTAssertEqual((Mirror(reflecting: standard).descendant("shortcut") as? KeyboardShortcut)?.key, LumenViewShortcuts.standard.panel?.key)
    }

    func testLogTimesAreTwentyFourHourInEveryLocale() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let date = calendar.date(from: DateComponents(year: 2026, month: 10, day: 11, hour: 14, minute: 36, second: 39))!
        XCTAssertEqual(date.formatted(LumenLogConsole.timeFormat), "14:36:39.000")
    }

    func testRegistryRejectsNothingValidAndThemesResolveWithoutCycles() {
        // A theme's own palette missing a component's sources resolves without recursion.
        let theme = LumenTheme(id: "partial", name: "Partial", light: ["bg.canvas": "#FFFFFF"], dark: nil)
        XCTAssertNotNil(theme.color(.fieldBackground, for: .light, in: .core))
    }
}

/// Components and behaviors an app would otherwise work around.
@MainActor
final class LumenAppGapTests: XCTestCase {
    func testWindowRolesCanBeReadThroughAnotherSurfacesTheme() throws {
        let store = TestPack.store(themes: LumenRegistry.core.builtInThemes)
        store.select(LumenThemes.standardID)
        store.select(LumenThemes.midnightID, for: TestPack.editor)
        let midnight = try XCTUnwrap(store.themes.first { $0.id == LumenThemes.midnightID })
        let standard = try XCTUnwrap(store.themes.first { $0.id == LumenThemes.standardID })
        XCTAssertEqual(try hex(store.nsColor(.fgPrimary, on: TestPack.editor), in: .aqua, space: .displayP3),
                       midnight.color(.fgPrimary, for: .dark, in: store.registry).hexString, "Editor rows: the editor's theme")
        XCTAssertEqual(try hex(store.nsColor(.fgPrimary), in: .aqua),
                       standard.color(.fgPrimary, for: .light, in: store.registry).hexString, "Chrome: the window's theme")
        XCTAssertNotEqual(store.resolvedPalette(on: TestPack.editor), store.resolvedPalette())
    }

    func testTheBreadcrumbNeverNeedsMoreThanATileAndAShortName() {
        let crumb = LumenToolbarBreadcrumb(["A long project name", "Sources", "a-very-long-file-name.swift"], systemImage: "cpu")
        XCTAssertLessThan(LumenLayout.minimumWidth(of: crumb), 120, "It shortens instead of drawing past its frame")
    }
}

import SwiftUI
import XCTest
import LumenTokens
import LumenUI
import LumenConformance

@MainActor
final class LumenConformanceTests: XCTestCase {
    func testLumensOwnThemesConform() {
        XCTAssertEqual(LumenConformance.themes(in: .core).map(\.description), [])
    }

    func testThemeFindingsNameTheThemeAndCanBeAllowedByMessage() {
        var midnight = LumenRegistry.core.theme(id: LumenThemes.midnightID)!
        let accent = midnight.dark?[.accent]
        midnight.dark?[.statusDanger] = accent
        let findings = LumenConformance.themes(in: .core, themes: [midnight])
        // The danger color now trips more than one rule (accent vs status, composited danger text…);
        // each names the theme.
        XCTAssertFalse(findings.isEmpty)
        XCTAssertEqual(Set(findings.map(\.subject)), ["Midnight"])
        let allowed = LumenConformance.themes(in: .core, themes: [midnight], allowing: ["Midnight": findings.map(\.message)])
        XCTAssertEqual(allowed, [])
    }

    func testLayoutFindsContentWiderThanItsColumnAndAShortWindowMinimum() {
        let columns = [
            LumenConformance.Column("Sidebar", minWidth: 200) { Color.clear.frame(minWidth: 180) },
            LumenConformance.Column("Detail", minWidth: 300) { HStack { Color.clear.frame(width: 250); Color.clear.frame(width: 100) } },
        ]
        let findings = LumenConformance.layout(windowMinWidth: 450, columns: columns)
        XCTAssertEqual(findings.map(\.subject), ["Detail", "window"])
        XCTAssertEqual(LumenConformance.layout(windowMinWidth: 500, columns: [columns[0]]), [])
    }

    func testShortcutsFindSharedOwnersReservedAndMisusedStandardShortcuts() {
        let findings = LumenConformance.shortcuts([
            ("Find in Project", KeyboardShortcut("f", modifiers: [.command, .shift])),
            ("Search Symbols", KeyboardShortcut("f", modifiers: [.command, .shift])),
            ("Quick Look", KeyboardShortcut(.space)),
            ("Toggle Sidebar", KeyboardShortcut("s")),
            ("Find", KeyboardShortcut("f")),
        ])
        XCTAssertEqual(findings.map(\.description), [
            "shortcut · ⇧⌘F: has 2 owners: Find in Project, Search Symbols",
            "shortcut · Quick Look: ⌘Space is macOS's Spotlight",
            "shortcut · Toggle Sidebar: ⌘S is every Mac app's Save",
        ])
        XCTAssertEqual(LumenConformance.shortcuts(LumenShortcuts.all), [], "Lumen's own shortcuts conform")
    }

    func testCoverageFindsUnregisteredKeys() {
        XCTAssertEqual(LumenConformance.coverage(in: .core, usedKeys: ["bg.canvas", "bg.canvs", "bg.canvas"]).map(\.subject), ["bg.canvs"])
    }
}

@MainActor
final class LumenThemeConformanceInputTests: XCTestCase {
    func testAThemeWithNothingToCheckIsAFinding() {
        let orphan = LumenTheme(id: "test.orphan", name: "Orphan", inherits: "missing-parent", light: nil, dark: nil)
        XCTAssertEqual(LumenConformance.themes(in: .core, themes: [orphan]).map(\.description),
                       ["theme · Orphan: it inherits unknown theme missing-parent"])
        let empty = LumenTheme(id: "test.empty", name: "Empty", light: nil, dark: nil)
        XCTAssertEqual(LumenConformance.themes(in: .core, themes: [empty]).map(\.description),
                       ["theme · Empty: declares no light or dark palette, so there is nothing to check"])
        // A child of a built-in is checked flattened: it has exactly its parent's findings.
        let child = LumenTheme(id: "test.child", name: "Child", inherits: LumenThemes.standardID, light: nil, dark: nil)
        let standard = LumenRegistry.core.theme(id: LumenThemes.standardID)!
        XCTAssertEqual(LumenConformance.themes(in: .core, themes: [child]).map(\.message),
                       LumenConformance.themes(in: .core, themes: [standard]).map(\.message))
    }
}

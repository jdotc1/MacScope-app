import AppKit
import SwiftUI
import XCTest
@testable import LumenUI

@MainActor
final class LumenCommandPaletteTests: XCTestCase {
    private func command(_ title: String, category: String = "View", keywords: [String] = []) -> LumenCommand {
        LumenCommand(title, category: category, systemImage: "circle", keywords: keywords) {}
    }

    func testTitlesMatchForgivinglyAndRankWordStartsFirst() {
        XCTAssertNotNil(LumenCommandMatcher.match("tgp", title: "Toggle Panel"), "Characters in order, not adjacent")
        XCTAssertNil(LumenCommandMatcher.match("ptg", title: "Toggle Panel"), "Order matters")
        let prefix = LumenCommandMatcher.match("hid", title: "Hide Panel")!.score
        let wordStart = LumenCommandMatcher.match("pan", title: "Hide Panel")!.score
        let scattered = LumenCommandMatcher.match("hdp", title: "Hide Panel")!.score
        XCTAssertGreaterThan(prefix, wordStart)
        XCTAssertGreaterThan(wordStart, scattered)
        XCTAssertEqual(LumenCommandMatcher.match("pan", title: "Hide Panel")?.offsets, [5, 6, 7])
    }

    func testKeywordsAndCategoriesMatchOnlyAtWordStartsAndRankBelowTitles() {
        XCTAssertNotNil(LumenCommandMatcher.match("pan", title: "Show Transcript", keywords: ["Panel"]))
        XCTAssertNil(LumenCommandMatcher.match("pan", title: "Use Midnight Theme", keywords: ["appearance"]),
                     "No scattered matches inside keywords")
        let commands = [command("Show Transcript", category: "Panel"), command("Hide Panel")]
        let rows = LumenCommandMatcher.rows(commands, query: "pan", recents: [])
        XCTAssertEqual(rows.map(\.command.title), ["Hide Panel", "Show Transcript"], "Title matches before category matches")
    }

    func testRecentCommandsComeFirstWithoutAQuery() {
        let commands = [command("A"), command("B"), command("C")]
        let rows = LumenCommandMatcher.rows(commands, query: "", recents: [commands[2].id, "gone"])
        XCTAssertEqual(rows.map(\.command.title), ["C", "A", "B"])
        XCTAssertEqual(rows.map(\.isRecent), [true, false, false])
        XCTAssertTrue(LumenCommandMatcher.rows(commands, query: "zzz", recents: []).isEmpty)
    }

    func testRecentsKeepTheLastFewMostRecentFirst() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "LumenCommandPaletteTests"))
        defaults.removePersistentDomain(forName: "LumenCommandPaletteTests")
        let recents = LumenCommandRecents(key: "recents", defaults: defaults)
        for id in ["a", "b", "c", "d", "e", "f", "b"] { recents.record(id) }
        XCTAssertEqual(recents.ids, ["b", "f", "e", "d", "c"])
        defaults.removePersistentDomain(forName: "LumenCommandPaletteTests")
    }

    func testInteractiveResultsDoNotMaterializeEveryRowButSnapshotsDo() {
        let count = 500
        func materializedRows(snapshot: Bool) -> Int {
            let counter = PaletteRowCounter()
            let hosting = NSHostingView(rootView: ScrollView {
                LumenCommandResultStack(isSnapshot: snapshot) {
                    ForEach(0 ..< count, id: \.self) { id in
                        CountedPaletteRow(id: id, counter: counter)
                    }
                }
            }
            .frame(maxHeight: 380)
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: 580, height: 380))
            hosting.frame = NSRect(x: 0, y: 0, width: 580, height: 380)
            hosting.layoutSubtreeIfNeeded()
            return counter.ids.count
        }
        let lazyCount = materializedRows(snapshot: false)
        XCTAssertGreaterThan(lazyCount, 0, "The bounded viewport must actually lay out rows")
        XCTAssertLessThan(lazyCount, count, "Interactive layout must not eagerly build all commands")
        XCTAssertEqual(materializedRows(snapshot: true), count, "Offscreen snapshots retain complete eager content")
    }

    func testLargeFilteredPalettePreservesCommandIDsAndEnabledSelection() {
        let commands = (0 ..< 500).map { index in
            LumenCommand(id: "command-\(index)", "Command \(index)", category: "View", systemImage: "circle",
                         isEnabled: index != 499) {}
        }
        let rows = LumenCommandMatcher.rows(commands, query: "Command 49", recents: [])
        let ids = rows.filter(\.command.isEnabled).map(\.command.id)
        XCTAssertTrue(ids.contains("command-49"))
        XCTAssertFalse(ids.contains("command-499"))
        XCTAssertEqual(LumenSelectionStep.next(ids, from: nil, by: 1), ids.first)
        XCTAssertEqual(LumenSelectionStep.next(ids, from: ids.last, by: 1), ids.last)
        XCTAssertEqual(Set(rows.map(\.command.id)).count, rows.count)
    }

    // Renaming the highlighted command out of the results moves the
    // highlight to a row that still shows (the old key held only ids and enabled states).
    func testRenamingTheHighlightedCommandOutOfTheResultsMovesTheHighlight() {
        let a = LumenCommand(id: "a", "Open File", category: "File", systemImage: "circle") {}
        let b = LumenCommand(id: "b", "Open Folder", category: "File", systemImage: "circle") {}
        let renamed = LumenCommand(id: "a", "Close File", category: "File", systemImage: "circle") {}
        XCTAssertNotEqual(LumenCommandPalette.rowsKey([a, b]), LumenCommandPalette.rowsKey([renamed, b]),
                          "A title change alone must recheck the highlight")
        XCTAssertNotEqual(LumenCommandPalette.rowsKey([a]),
                          LumenCommandPalette.rowsKey([LumenCommand(id: "a", "Open File", category: "File", systemImage: "circle",
                                                                    keywords: ["load"]) {}]))
        let rows = LumenCommandMatcher.rows([renamed, b], query: "Open", recents: [])
        XCTAssertEqual(rows.map(\.command.id), ["b"])
        XCTAssertEqual(LumenCommandPalette.repairedHighlight("a", in: rows), "b")
        XCTAssertEqual(LumenCommandPalette.repairedHighlight("b", in: rows), "b", "A highlight still showing stays")
    }

    // Closing clears focus only in the palette's own window, while
    // it's key, and only when focus fell into a field after closing.
    func testClosingClearsFocusOnlyWhenItFellIntoAFieldInThePalettesKeyWindow() {
        func window() -> (NSWindow, NSTextField, NSTextField) {
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let a = NSTextField(frame: CGRect(x: 0, y: 0, width: 100, height: 22)), b = NSTextField(frame: CGRect(x: 0, y: 40, width: 100, height: 22))
            window.contentView?.addSubview(a)
            window.contentView?.addSubview(b)
            return (window, a, b)
        }
        let (palette, filter, editor) = window()
        let (other, otherField, _) = window()
        XCTAssertTrue(palette.makeFirstResponder(filter))
        XCTAssertTrue(LumenPalettePresenter.editedControl(palette.firstResponder) === filter, "A field editor stands for its field")

        // Focus fell into the filter after closing (the palette's field had it): clear it.
        XCTAssertTrue(LumenPalettePresenter.shouldClearFocus(in: palette, keyWindow: palette, editingAtClose: nil))
        // Another window is key now (a command opened it, or the person switched): leave it alone.
        XCTAssertFalse(LumenPalettePresenter.shouldClearFocus(in: palette, keyWindow: other, editingAtClose: nil))
        // A command put focus in a field before the palette closed: it stays.
        XCTAssertTrue(palette.makeFirstResponder(editor))
        XCTAssertFalse(LumenPalettePresenter.shouldClearFocus(in: palette, keyWindow: palette, editingAtClose: editor))
        // Nothing focused but the window: nothing to clear.
        palette.makeFirstResponder(nil)
        XCTAssertFalse(LumenPalettePresenter.shouldClearFocus(in: palette, keyWindow: palette, editingAtClose: nil))
        XCTAssertTrue(other.makeFirstResponder(otherField))
        palette.close()
        other.close()
    }
}

@MainActor
private final class PaletteRowCounter {
    var ids = Set<Int>()
}

private struct CountedPaletteRow: View {
    let id: Int
    let counter: PaletteRowCounter
    var body: some View {
        counter.ids.insert(id)
        return Text("Command \(id)").frame(height: 38)
    }
}

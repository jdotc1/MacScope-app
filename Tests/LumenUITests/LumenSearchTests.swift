import XCTest
@testable import LumenUI

@MainActor
final class LumenSearchTests: XCTestCase {
    func testScopePrefixesSwitchScopeAndStripThePrefix() {
        let scopes = [LumenPaletteScope("All", prefix: nil), LumenPaletteScope("Files", prefix: "/"), LumenPaletteScope("Symbols", prefix: "#")]
        let symbols = LumenPaletteScope.resolve("#comp", in: scopes)
        XCTAssertEqual(symbols.scope?.id, "Symbols")
        XCTAssertEqual(symbols.query, "comp")
        let plain = LumenPaletteScope.resolve("comp", in: scopes)
        XCTAssertEqual(plain.scope?.id, "All")
        XCTAssertEqual(plain.query, "comp")
        XCTAssertEqual(LumenPaletteScope.resolve("/", in: scopes).query, "")
    }

    func testScopesIncludeTheirCommandsAndAllIncludesEverything() {
        let all = LumenPaletteScope("All", prefix: nil), files = LumenPaletteScope("Files", prefix: "/")
        let file = LumenCommand("Main.swift", category: "Files", systemImage: "doc", scope: "Files") {}
        let command = LumenCommand("Toggle Panel", category: "View", systemImage: "rectangle") {}
        XCTAssertTrue(all.includes(file) && all.includes(command))
        XCTAssertTrue(files.includes(file))
        XCTAssertFalse(files.includes(command))
    }

    func testHighlightRangesFindEveryOccurrenceIgnoringCase() {
        XCTAssertEqual(LumenHighlightedText.ranges(of: "stat", in: "LumenStat lumenstat STAT"), [5..<9, 15..<19, 20..<24])
        XCTAssertEqual(LumenHighlightedText.ranges(of: "", in: "abc"), [])
    }

    /// C-31: a match far into its line keeps itself visible; the leading context is trimmed instead.
    func testMatchLinesTrimLeadingContextSoTheMatchShows() {
        let text = "                    let value = computeSomething(); return LumenStat(count)"
        let start = (text as NSString).range(of: "LumenStat").location
        let match = LumenSearchMatch(line: 7, text: text, ranges: [start..<(start + 9)])
        let shown = LumenSearchResults.displayed(match)
        XCTAssertTrue(shown.text.hasPrefix("…"))
        let range = try! XCTUnwrap(shown.ranges.first)
        XCTAssertLessThanOrEqual(range.lowerBound, LumenSearchResults.leadingContext + 1)
        XCTAssertEqual(String(Array(shown.text)[range]), "LumenStat")
        XCTAssertEqual(shown.text, "…); return LumenStat(count)", "the cut lands on a token boundary")
        let near = LumenSearchMatch(line: 1, text: "LumenStat()", ranges: [0..<9])
        XCTAssertEqual(LumenSearchResults.displayed(near).text, "LumenStat()")
    }

    func testSummaryCountsResultsAndFiles() {
        let a = LumenSearchFile(id: "a", name: "a", matches: [LumenSearchMatch(line: 1, text: "x", ranges: [0..<1]),
                                                              LumenSearchMatch(line: 2, text: "x", ranges: [0..<1])])
        let b = LumenSearchFile(id: "b", name: "b", matches: [LumenSearchMatch(line: 3, text: "x", ranges: [0..<1])])
        XCTAssertEqual(LumenSearchResults.summary([a, b]), "3 results in 2 files")
        XCTAssertEqual(LumenSearchResults.summary([b]), "1 result in 1 file")
        XCTAssertEqual(LumenSearchResults.summary([]), "No results")
    }

    func testGoToLineParsesLineAndColumn() {
        XCTAssertEqual(LumenGoToLine.parse("12")?.line, 12)
        XCTAssertNil(LumenGoToLine.parse("12")?.column)
        XCTAssertEqual(LumenGoToLine.parse(" 12:30 ")?.column, 30)
        XCTAssertNil(LumenGoToLine.parse("0"))
        XCTAssertNil(LumenGoToLine.parse("12:"))
        XCTAssertNil(LumenGoToLine.parse("abc"))
        XCTAssertNil(LumenGoToLine.parse("1:2:3"))
    }
}

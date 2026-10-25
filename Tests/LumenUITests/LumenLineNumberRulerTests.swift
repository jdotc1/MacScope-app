import AppKit
import XCTest
import LumenTokens
@testable import LumenUI

@MainActor
final class LumenLineNumberRulerTests: XCTestCase {
    func testCountsLinesAndFindsTheLineOfAnIndex() {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        let text = NSTextView(frame: scroll.bounds)
        scroll.documentView = text
        text.string = "int a;\nreturn a;\n}"
        let ruler = LumenLineNumberRuler.install(on: text, palette: LumenThemeStore.active.resolvedPalette())
        XCTAssertEqual(ruler.lineStarts, [0, 7, 17])
        XCTAssertEqual(ruler.line(at: 0), 0)
        XCTAssertEqual(ruler.line(at: 8), 1)
        XCTAssertEqual(ruler.line(at: 17), 2)
        XCTAssertTrue(scroll.rulersVisible)

        text.textStorage?.replaceCharacters(in: NSRange(location: text.string.count, length: 0), with: "\n")
        XCTAssertEqual(ruler.lineStarts.count, 4, "A trailing newline starts an empty last line")
    }
}

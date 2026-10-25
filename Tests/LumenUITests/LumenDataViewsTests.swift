import AppKit
import XCTest
@testable import LumenUI

@MainActor
final class LumenDataViewsTests: XCTestCase {
    func testOutlineDepthCollapsesParentsAtTheChosenDepth() {
        let items: [(id: String, depth: Int)] = [("A", 0), ("A1", 1), ("A1a", 2), ("A2", 1), ("B", 0)]
        XCTAssertEqual(LumenOutlineDepth.collapsedIDs(items, showing: 1), ["A", "A1"], "Deeper parents close too")
        XCTAssertEqual(LumenOutlineDepth.collapsedIDs(items, showing: 2), ["A1"])
        XCTAssertEqual(LumenOutlineDepth.collapsedIDs(items, showing: 3), [])
    }

    func testAvatarHueIsStableForAName() {
        XCTAssertEqual(LumenAvatar.hue(for: "avery"), LumenAvatar.hue(for: "avery"))
        XCTAssertTrue(LumenAvatar.hues.contains(LumenAvatar.hue(for: "")))
    }

    func testMinimapViewportStaysInsideTheDocument() {
        let middle = LumenMinimap.viewport(centredOn: 0.5, size: 0.2)
        XCTAssertEqual(middle.lowerBound, 0.4, accuracy: 1e-9)
        XCTAssertEqual(middle.upperBound, 0.6, accuracy: 1e-9)
        XCTAssertEqual(LumenMinimap.viewport(centredOn: 0.02, size: 0.2), 0...0.2)
        let end = LumenMinimap.viewport(centredOn: 0.99, size: 0.2)
        XCTAssertEqual(end.lowerBound, 0.8, accuracy: 1e-9)
        XCTAssertEqual(end.upperBound, 1, accuracy: 1e-9)
    }

    @MainActor func testRulerFindsTheLineUnderAClick() {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        let text = NSTextView(frame: scroll.bounds)
        scroll.documentView = text
        text.string = "one\ntwo\nthree"
        let ruler = LumenLineNumberRuler.install(on: text, palette: LumenThemeStore.active.resolvedPalette())
        text.layoutManager?.ensureLayout(for: text.textContainer!)
        let lineHeight = text.layoutManager!.defaultLineHeight(for: text.font ?? .systemFont(ofSize: 12))
        let point = ruler.convert(NSPoint(x: 1, y: text.textContainerOrigin.y + lineHeight * 1.5), from: text)
        XCTAssertEqual(ruler.line(atRulerPoint: point), 1)
    }
}

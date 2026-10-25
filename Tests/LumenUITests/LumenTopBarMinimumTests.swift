import AppKit
import XCTest
@testable import LumenUI

/// The unified top bar counts the title bar band in the window's minimum height once per window,
/// whichever bar view does it, and takes it back out when the last one goes.
@MainActor
final class LumenTopBarMinimumTests: XCTestCase {
    private func window() -> NSWindow {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSView()
        window.contentMinSize = CGSize(width: 400, height: 300)
        return window
    }

    func testAReplacedBarDoesNotCountTheBandTwiceAndTheLastOneTakesItBack() throws {
        let window = window()
        defer { window.close() }
        let band = window.frame.height - window.contentLayoutRect.height
        try XCTSkipIf(band < 0.5, "this window has no title bar band")
        let first = LumenToolbarPriorities.PriorityView()
        window.contentView?.addSubview(first)
        first.countBandInMinimum()
        XCTAssertEqual(window.contentMinSize.height, 300 + band, accuracy: 0.5)

        // SwiftUI remounts the bar: a new view on the same window, the old one still there a moment.
        let second = LumenToolbarPriorities.PriorityView()
        window.contentView?.addSubview(second)
        second.countBandInMinimum()
        XCTAssertEqual(window.contentMinSize.height, 300 + band, accuracy: 0.5, "the band was counted twice")

        first.removeFromSuperview()
        LumenToolbarPriorities.dismantleNSView(first, coordinator: ())
        XCTAssertEqual(window.contentMinSize.height, 300 + band, accuracy: 0.5, "a remaining bar lost the band")

        // Unified → under the title bar: the last bar goes and the app's own minimum comes back.
        second.removeFromSuperview()
        LumenToolbarPriorities.dismantleNSView(second, coordinator: ())
        XCTAssertEqual(window.contentMinSize.height, 300, accuracy: 0.5, "the band stayed in the minimum")

        // … and back to unified: counted once again.
        let third = LumenToolbarPriorities.PriorityView()
        window.contentView?.addSubview(third)
        third.countBandInMinimum()
        XCTAssertEqual(window.contentMinSize.height, 300 + band, accuracy: 0.5)
    }
}

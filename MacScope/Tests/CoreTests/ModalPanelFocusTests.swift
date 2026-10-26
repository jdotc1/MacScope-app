import AppKit
import XCTest
@testable import MacScope

/// Save panels run from a Task give key status back to the issuing window afterwards, so a result
/// or error alert takes Return/Escape (Tier 2: the Patched Binary alert; now every export save panel).
@MainActor
final class ModalPanelFocusTests: XCTestCase {
    @MainActor private final class RecordingWindow: KeyWindowRestorable {
        var events: [String] = []
        func makeKeyAndOrderFront(_ sender: Any?) { events.append("restore") }
    }

    func testTheHostIsRestoredAfterThePanelWhateverItReturns() {
        for expected in [NSApplication.ModalResponse.OK, .cancel] {
            let host = RecordingWindow()
            let response = ModalPanelFocus.run(host: host) { () -> NSApplication.ModalResponse in
                host.events.append("panel")
                return expected
            }
            XCTAssertEqual(response, expected)
            XCTAssertEqual(host.events, ["panel", "restore"], "Restored once, after the panel closes")
        }
    }

    func testNoHostIsHarmless() {
        XCTAssertEqual(ModalPanelFocus.run(host: nil) { 7 }, 7)
    }
}

import XCTest
@testable import LumenUI

@MainActor final class LumenPickersTests: XCTestCase {
    func testPermissionsRoundTrip() {
        XCTAssertEqual(LumenPermissionsGrid.octal(0o644), "0644")
        XCTAssertEqual(LumenPermissionsGrid.octal(0o7), "0007")
        XCTAssertEqual(LumenPermissionsGrid.symbolic(0o644), "rw-r--r--")
        XCTAssertEqual(LumenPermissionsGrid.symbolic(0o755), "rwxr-xr-x")
        XCTAssertEqual(LumenPermissionsGrid.mode(from: "0755"), 0o755)
        XCTAssertEqual(LumenPermissionsGrid.mode(from: "644"), 0o644)
        XCTAssertNil(LumenPermissionsGrid.mode(from: "0899"))
        XCTAssertNil(LumenPermissionsGrid.mode(from: "64"))
    }

    func testSwatchStripRendersAsAnImage() {
        let image = LumenSwatchStrip.image([.red, .green, .blue])
        XCTAssertNotNil(image)
        XCTAssertEqual(image?.isTemplate, false)
    }
}

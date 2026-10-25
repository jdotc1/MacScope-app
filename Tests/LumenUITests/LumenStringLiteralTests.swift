import XCTest
@testable import LumenUI

@MainActor
final class LumenStringLiteralTests: XCTestCase {
    typealias P = LumenStringLiteral.Part

    func testSplitsEscapesAndFormatSpecifiers() {
        XCTAssertEqual(LumenStringLiteral.parts("%s: bad (%02x)\\n"),
                       [.format("%s"), .literal(": bad ("), .format("%02x"), .literal(")"), .escape("\\n")])
    }

    func testHandlesHexEscapesPercentLiteralsAndObjects() {
        XCTAssertEqual(LumenStringLiteral.parts("\\x1b[31m100%% %@ %lld"),
                       [.escape("\\x1b"), .literal("[31m100"), .format("%%"), .literal(" "), .format("%@"), .literal(" "), .format("%lld")])
    }

    func testAStrayPercentStaysLiteral() {
        XCTAssertEqual(LumenStringLiteral.parts("50% off"), [.literal("50% off")])
    }
}

import XCTest
@testable import MacScope

final class MacIRNEONBroadcastMemoryTests: XCTestCase {
    func testFootprintAndDelayedCommitAreDistinctFromDestinationWidth() throws {
        let frame = try XCTUnwrap(MacIRNEONBroadcastMemory(elementBytes: 2, activeBytes: 16,
            baseRegister: "x0", oldBase: .register(name: "x0", version: 0),
            destination: .register(name: "v0", version: 1), baseDestination: .register(name: "x0", version: 1), sequence: 0))
        XCTAssertEqual(frame.byteCount, 2)
        XCTAssertEqual(frame.laneCount, 8)
        XCTAssertEqual(frame.fixedPostDelta, 2)
        XCTAssertEqual(frame.effectCount, 2)
        XCTAssertNotNil(MacIRNEONBroadcastMemoryStep(frame: frame, ordinal: 1))
        XCTAssertNil(MacIRNEONBroadcastMemoryStep(frame: frame, ordinal: 2))
        XCTAssertNil(MacIRNEONBroadcastMemory(elementBytes: 8, activeBytes: 8,
            baseRegister: "x0", oldBase: .register(name: "x0", version: 0),
            destination: .register(name: "v0", version: 1), baseDestination: nil, sequence: 0))
    }
}

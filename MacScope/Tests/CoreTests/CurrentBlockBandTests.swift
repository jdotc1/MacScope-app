import XCTest
@testable import MacScope

@MainActor
final class CurrentBlockBandTests: XCTestCase {
    private func block(_ start: UInt64, _ end: UInt64) -> BasicBlockSummary {
        BasicBlockSummary(id: UUID(), functionID: UUID(), startAddress: start, endAddress: end, instructionCount: 1)
    }
    private let slot = ImageSlot.primary

    func testBandCoversTheSelectedInstructionsBlock() throws {
        let blocks = [block(0x100, 0x110), block(0x110, 0x120)]
        let band = try XCTUnwrap(CurrentBlockBand.resolve(selection: ImageAddress(slot: slot, address: 0x108), blocks: blocks))
        XCTAssertEqual(band.range, 0x100..<0x110)
        XCTAssertTrue(band.contains(ImageAddress(slot: slot, address: 0x10C)))
        XCTAssertFalse(band.contains(ImageAddress(slot: slot, address: 0x110)))
        XCTAssertFalse(band.contains(ImageAddress(slot: ImageSlot(rawValue: 1), address: 0x104)))
    }

    func testOverlappingBlockEndsAreClippedToTheNextBlock() {
        let blocks = [block(0x200, 0x20B), block(0x204, 0x210)]
        XCTAssertEqual(CurrentBlockBand.resolve(selection: ImageAddress(slot: slot, address: 0x200), blocks: blocks)?.range, 0x200..<0x204)
        XCTAssertEqual(CurrentBlockBand.resolve(selection: ImageAddress(slot: slot, address: 0x206), blocks: blocks)?.range, 0x204..<0x210)
    }

    func testNoBandWithoutAnOwningBlock() {
        let blocks = [block(0x100, 0x110), block(0x200, 0x210)]
        XCTAssertNil(CurrentBlockBand.resolve(selection: nil, blocks: blocks))
        XCTAssertNil(CurrentBlockBand.resolve(selection: ImageAddress(slot: slot, address: 0x150), blocks: blocks))
        XCTAssertNil(CurrentBlockBand.resolve(selection: ImageAddress(slot: slot, address: 0x50), blocks: blocks))
    }
}

import XCTest
@testable import MacScope

final class MacIRNEONRoundedNarrowBufferTests: XCTestCase {
    func testExhaustivePureCompositionMap() {
        let entries: [MacIRNEONRoundedNarrowBuffer.Entry] = [
            .init(family: .rounded, rowOrdinal: 0, identity: .init(sourceAddress: 0x1000, effectOrdinal: 0)),
            .init(family: .narrow, rowOrdinal: 1, identity: .init(sourceAddress: 0x1004, effectOrdinal: 0)),
            .init(family: .terminal, rowOrdinal: 2, identity: .init(sourceAddress: 0x1008, effectOrdinal: 0))
        ]
        let certificate = MacIRNEONRoundedNarrowBuffer(entries: entries)
        XCTAssertEqual(certificate?.rowCount, 3)
        XCTAssertEqual(certificate?.effectCount, 3)
        XCTAssertEqual(certificate?.qTransferCount, 0)
        XCTAssertEqual(certificate?.memoryByteCount, 0)
        XCTAssertNil(MacIRNEONRoundedNarrowBuffer(entries: Array(entries.dropLast())))
        XCTAssertNil(MacIRNEONRoundedNarrowBuffer(entries: []))
    }
}

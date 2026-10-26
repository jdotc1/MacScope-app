import XCTest
@testable import MacScope

final class MacIRNEONProductPairwiseBufferTests: XCTestCase {
    func testCompleteOriginalRowsAndDistinctQOrdinals() throws {
        let families: [MacIRNEONProductPairwiseBuffer.Family] = [.loadQ,.product,.signedPairwise,.storeQ,.terminal]
        let entries = families.enumerated().map { ordinal, family in
            MacIRNEONProductPairwiseBuffer.Entry(family: family, rowOrdinal: ordinal,
                identity: .init(sourceAddress: 4096 + UInt64(ordinal * 4), effectOrdinal: 0),
                qTransferOrdinal: family == .loadQ ? 0 : family == .storeQ ? 1 : nil)
        }
        let certificate = try XCTUnwrap(MacIRNEONProductPairwiseBuffer(entries: entries))
        XCTAssertEqual(certificate.rowCount, 5)
        XCTAssertEqual(certificate.effectCount, 5)
        XCTAssertEqual(certificate.qTransferCount, 2)
        XCTAssertEqual(certificate.memoryByteCount, 32)
        XCTAssertNil(MacIRNEONProductPairwiseBuffer(entries: Array(entries.dropLast())))
    }
    func testProductAndPairAreBothRequired() {
        let entries: [MacIRNEONProductPairwiseBuffer.Entry] = [
            .init(family: .product, rowOrdinal: 0, identity: .init(sourceAddress: 4096, effectOrdinal: 0)),
            .init(family: .terminal, rowOrdinal: 1, identity: .init(sourceAddress: 4100, effectOrdinal: 0))]
        XCTAssertNil(MacIRNEONProductPairwiseBuffer(entries: entries))
    }
    func testForeignEffectOrdinalCannotBecomeOriginalRow() {
        let entries: [MacIRNEONProductPairwiseBuffer.Entry] = [
            .init(family: .product, rowOrdinal: 0, identity: .init(sourceAddress: 4096, effectOrdinal: 0)),
            .init(family: .signedPairwise, rowOrdinal: 1, identity: .init(sourceAddress: 4100, effectOrdinal: 1)),
            .init(family: .terminal, rowOrdinal: 2, identity: .init(sourceAddress: 4104, effectOrdinal: 0))]
        XCTAssertNil(MacIRNEONProductPairwiseBuffer(entries: entries))
    }
}

import XCTest
@testable import MacScope
final class MacIRNEONPopulationCountFMOVTests: XCTestCase {
    func testClosedFiveRowCertificateRejectsEmptyAndDiscardOnly() {
        XCTAssertNil(MacIRNEONPopulationCountFMOV(entries: []))
        let families: [MacIRNEONPopulationCountFMOV.Family] = [.loadQ,.count16b,.unsignedSumH,.fmovHZeroComplement,.terminal]
        let entries = families.enumerated().map { ordinal, family in
            MacIRNEONPopulationCountFMOV.Entry(family: family,rowOrdinal: ordinal,identity: .init(sourceAddress: 4096 + UInt64(ordinal * 4),effectOrdinal: 0),qTransferOrdinal: ordinal == 0 ? 0 : nil,source: (1...3).contains(ordinal) ? .register(name:"v0",version:ordinal) : nil,destination: ordinal == 3 ? .register(name:"wzr",version:0) : (1...2).contains(ordinal) ? .register(name:"v0",version:ordinal+1) : nil)
        }
        XCTAssertNil(MacIRNEONPopulationCountFMOV(entries:entries))
    }
}

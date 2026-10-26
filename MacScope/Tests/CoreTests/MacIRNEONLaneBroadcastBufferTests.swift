import XCTest
@testable import MacScope

final class MacIRNEONLaneBroadcastBufferTests: XCTestCase {
    func testOriginalOrdinalUnitsRemainDistinct() throws {
        typealias E = MacIRNEONLaneBroadcastBuffer.Entry
        func entry(_ family: MacIRNEONLaneBroadcastBuffer.Family, _ position: Int, _ ordinal: Int, _ bytes: Int, _ first: Int,
                   _ scalar: Int?, _ lane: Int?, _ laneByte: Int?, _ q: Int?) -> E {
            E(family:family,startEffect:position,identities:[.init(sourceAddress:4096+UInt64(position*4),effectOrdinal:0)],
              transferOrdinal:ordinal,firstPayloadByte:first,byteCount:bytes,scalarQSequence:scalar,
              laneFrameSequence:lane,laneFirstByteSequence:laneByte,qOrdinal:q)
        }
        let entries = [entry(.q,0,0,16,0,0,nil,nil,0), entry(.broadcast,1,1,4,16,1,nil,nil,nil),
                       entry(.lane,2,2,2,20,nil,0,0,nil), entry(.q,3,3,16,22,2,nil,nil,1)]
        let map = try XCTUnwrap(MacIRNEONLaneBroadcastBuffer(entries:entries,effectCount:5,rowCount:5))
        XCTAssertEqual(map.scalarQTransfers,3); XCTAssertEqual(map.qTransfers,2)
        XCTAssertEqual(map.laneFrames,1); XCTAssertEqual(map.laneBytes,2)
        XCTAssertNil(MacIRNEONLaneBroadcastBuffer(entries:Array(entries.dropFirst()),effectCount:5,rowCount:5))
    }
}

import XCTest
@testable import MacScope

final class MacIRNEONWiderMultiChannelReplicateTests: XCTestCase {
    func testExactHChannelSpanAndWrappedDefinitions() throws {
        let word: UInt32 = 0x0d40c000 | 0x400 | 0x200000 | 0x40000000 | 0x009f0000 | 12<<5 | 31
        let f = try XCTUnwrap(MacIRNEONWiderMultiChannelReplicate(
            encodedWord:word,elementBytes:2,activeBytes:16,baseRegister:"x12",
            oldBase:.register(name:"x12",version:0),
            vectors:[.register(name:"v31",version:1),.register(name:"v0",version:1)],
            baseDestination:.register(name:"x12",version:1),frameSequence:0,firstByteSequence:0))
        XCTAssertEqual(f.byteCount,4)
        XCTAssertEqual(f.fixedPostDelta,4)
        XCTAssertEqual(f.vectorFootprint,32)
        XCTAssertEqual(f.effectCount,3)
        XCTAssertEqual(f.orderedReads.map(\.channel),[0,0,1,1])
        XCTAssertEqual(f.orderedReads.map(\.offset),[0,1,2,3])
        XCTAssertNil(MacIRNEONWiderMultiChannelReplicateStep(frame:f,ordinal:3))
    }
    func testByteWordCannotAcquireWiderSemantics() {
        XCTAssertNil(MacIRNEONWiderMultiChannelReplicate(
            encodedWord:0x4d60c000,elementBytes:2,activeBytes:16,baseRegister:"x0",
            oldBase:.register(name:"x0",version:0),
            vectors:[.register(name:"v0",version:1),.register(name:"v1",version:1)],
            baseDestination:nil,frameSequence:0,firstByteSequence:0))
    }
}

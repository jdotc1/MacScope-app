import XCTest
@testable import MacScope

/// Source-only native integration obligation. Portable main executes the actual
/// full decoder/builder and diagnostic-erased typed consumer for the new cases.
final class MacIRNEONGroupWidenNarrowTests: XCTestCase {
    func testDistinctFrameByteAndCommitMap() throws {
        typealias Entry = MacIRNEONGroupWidenNarrow.Entry
        func identities(_ pc:UInt64,_ count:Int)->[MacIRInstruction.Identity] {
            (0..<count).map { .init(sourceAddress:pc,effectOrdinal:$0) }
        }
        let entries:[Entry]=[
            .init(family:.loadGroup,rowOrdinal:0,startEffect:0,identities:identities(0x1000,5),frameSequence:0,firstByteSequence:0,activeBytes:16,memoryBlockCount:4,baseCommitOrdinal:4),
            .init(family:.widening,rowOrdinal:1,startEffect:5,identities:identities(0x1004,1)),
            .init(family:.narrow,rowOrdinal:2,startEffect:6,identities:identities(0x1008,1)),
            .init(family:.storeGroup,rowOrdinal:3,startEffect:7,identities:identities(0x100c,2),frameSequence:1,firstByteSequence:64,activeBytes:8,memoryBlockCount:2),
            .init(family:.terminal,rowOrdinal:4,startEffect:9,identities:identities(0x1010,1))
        ]
        let map=try XCTUnwrap(MacIRNEONGroupWidenNarrow(entries:entries,effectCount:10))
        XCTAssertEqual(map.rowCount,5);XCTAssertEqual(map.groupFrames,2)
        XCTAssertEqual(map.payloadBytes,80);XCTAssertEqual(map.memoryBlocks,6)
        XCTAssertEqual(map.delayedBaseCommits,1)
        XCTAssertEqual(Set([map,map]).count,1)
        var wrong=entries
        wrong[3] = .init(family:.storeGroup,rowOrdinal:3,startEffect:7,identities:identities(0x100c,2),frameSequence:1,firstByteSequence:4,activeBytes:8,memoryBlockCount:2)
        XCTAssertNil(MacIRNEONGroupWidenNarrow(entries:wrong,effectCount:10))
        wrong=entries
        wrong[0] = .init(family:.loadGroup,rowOrdinal:0,startEffect:0,identities:identities(0x1000,5),frameSequence:0,firstByteSequence:0,activeBytes:16,memoryBlockCount:4,baseCommitOrdinal:3)
        XCTAssertNil(MacIRNEONGroupWidenNarrow(entries:wrong,effectCount:10))
    }
}

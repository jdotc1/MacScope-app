import XCTest
@testable import MacScope

/// Source-only native topic. No predecessor machine-state replay.
final class MacIRNEONWiderLanePackingTests:XCTestCase {
    func testSelectedBitMappingNotWholeVectorTaint() {
        var a=NEONWiderLanePackingAncestry()
        let source=MacIRValue.register(name:"v0",version:1)
        var bits:[NEONWiderLanePackingAncestry.Bit?]=Array(repeating:nil,count:128)
        for b in 0..<16 { bits[112+b] = .init(frame:0,channel:0,inputBit:b,laneBits:16,transformed:false) }
        a.values[source]=bits
        let dest=MacIRValue.register(name:"v0",version:2)
        XCTAssertFalse(a.packed(.init(kind:.signedWiden,narrowBits:16)!,source:source,old:nil,destination:dest))
        XCTAssertTrue(a.packed(.init(kind:.signedWiden,narrowBits:16,sourceHighHalf:true)!,source:source,old:nil,destination:dest))
        XCTAssertTrue(a.values[dest]![0..<96].allSatisfy {$0 == nil})
        XCTAssertEqual(a.values[dest]![127]?.inputBit,15)
        XCTAssertEqual(a.values[dest]![96]?.inputBit,0)
    }
    func testShiftZeroAndXTN2LatestLow() {
        var a=NEONWiderLanePackingAncestry()
        let source=MacIRValue.register(name:"v2",version:1),old=MacIRValue.register(name:"v3",version:2),dest=MacIRValue.register(name:"v3",version:3)
        var bits:[NEONWiderLanePackingAncestry.Bit?]=Array(repeating:nil,count:128)
        for b in 0..<32 { bits[b] = .init(frame:2,channel:0,inputBit:b,laneBits:32,transformed:false) }
        a.values[source]=bits
        var prior:[NEONWiderLanePackingAncestry.Bit?]=Array(repeating:nil,count:128)
        prior[0] = .init(frame:1,channel:0,inputBit:0,laneBits:16,transformed:true);a.values[old]=prior
        XCTAssertTrue(a.packed(.init(kind:.narrow,narrowBits:16,destinationHighHalf:true)!,source:source,old:old,destination:dest))
        XCTAssertEqual(a.values[dest]![0],prior[0]);XCTAssertEqual(a.values[dest]![64]?.inputBit,0)
        XCTAssertNil(a.values[dest]![80])
    }
}

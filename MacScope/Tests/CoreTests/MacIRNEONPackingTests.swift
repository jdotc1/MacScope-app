import XCTest
@testable import MacScope

final class MacIRNEONPackingTests: XCTestCase {
    func testDistinctHalfRolesAndBounds() {
        XCTAssertNil(MacIRNEONPacking(kind:.signedWiden,narrowBits:8,destinationHighHalf:true))
        XCTAssertNil(MacIRNEONPacking(kind:.narrow,narrowBits:16,sourceHighHalf:true))
        XCTAssertNil(MacIRNEONPacking(kind:.unsignedWiden,narrowBits:32,shift:32))
        let low = MacIRNEONPacking(kind:.narrow,narrowBits:32)!
        let high = MacIRNEONPacking(kind:.narrow,narrowBits:32,destinationHighHalf:true)!
        let source = (low:UInt64(0xabcdef0198765432),high:UInt64(0xfedcba0912345678))
        let old = (low:UInt64(0x1111222233334444),high:UInt64.max)
        XCTAssertEqual(low.evaluate(source:source,oldDestination:old).low,0x1234567898765432)
        XCTAssertEqual(low.evaluate(source:source,oldDestination:old).high,0)
        XCTAssertEqual(high.evaluate(source:source,oldDestination:old).low,old.low)
        XCTAssertEqual(high.evaluate(source:source,oldDestination:old).high,0x1234567898765432)
    }
}

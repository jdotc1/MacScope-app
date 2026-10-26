import XCTest
@testable import MacScope

final class MacIRNEONReplicatedIndexedProductTests: XCTestCase {
    func testMarkerBoundsAndPreservedPhysicalIdentity() {
        XCTAssertNil(MacIRNEONReplicatedIndexedProduct(ordinal:-1))
        XCTAssertNil(MacIRNEONReplicatedIndexedProduct(ordinal:316))
        var instruction=MacIRInstruction(source:.init(address:4096,byteText:"",mnemonic:"nop",operands:"",comment:nil),operation:.intrinsic(destination:nil,name:"nop",arguments:[]))
        let original=instruction.id
        instruction.neonReplicatedIndexedProduct = .init(ordinal:5)
        XCTAssertEqual(instruction.id,original)
    }
    func testSelectedRolesRemainIndependentOfQ() {
        let signed=MacIRNEONSelectedSignedMultiply(narrowBits:16,sourceHighHalf:false,selectedLane:7)!
        let unsigned=MacIRNEONSelectedUnsignedMultiply(narrowBits:32,sourceHighHalf:true,selectedLane:3)!
        XCTAssertEqual(signed.coefficient.index,7)
        XCTAssertFalse(signed.firstSource.highHalf)
        XCTAssertTrue(signed.coefficient.signed)
        XCTAssertEqual(unsigned.coefficient.index,3)
        XCTAssertTrue(unsigned.firstSource.highHalf)
        XCTAssertFalse(unsigned.coefficient.signed)
    }
}

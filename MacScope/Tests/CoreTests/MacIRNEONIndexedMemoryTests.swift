import XCTest
@testable import MacScope

/// New41 scope only. Native execution/target membership remain owner-owned.
final class MacIRNEONIndexedMemoryTests: XCTestCase {
    func testIndexedDescriptorHasTypedAddressAndValueIdentity() throws {
        let d = try XCTUnwrap(MacIRNEONIndexedMemory(effect:.load,baseRegister:"x0",indexRegister:"w2",
            base:.register(name:"x0",version:0),index:.register(name:"w2",version:0),indexExtension:.sxtw,shift:4,sequence:0))
        XCTAssertEqual(d.byteWidth,16)
        XCTAssertEqual(Set([d,d]).count,1)
        XCTAssertNotEqual(d.address,d.base)
        XCTAssertNil(MacIRNEONIndexedMemory(effect:.load,baseRegister:"sp",indexRegister:"w2",
            base:.register(name:"sp",version:0),index:.register(name:"w2",version:0),indexExtension:.sxtw,shift:4,sequence:0))
        XCTAssertNil(MacIRNEONIndexedMemory(effect:.load,baseRegister:"x0",indexRegister:"xzr",
            base:.register(name:"x0",version:0),index:.register(name:"xzr",version:1),indexExtension:.lsl,shift:0,sequence:0))
    }
}

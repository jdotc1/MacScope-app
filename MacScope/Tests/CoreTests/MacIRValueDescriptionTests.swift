import XCTest
@testable import MacScope

final class MacIRValueDescriptionTests: XCTestCase {
    func testMinimumSignedImmediateDescribesWithoutOverflow() {
        XCTAssertEqual(MacIRValue.immediate(Int64.min).description, "-0x8000000000000000")
        XCTAssertEqual(MacIRValue.stackSlot(offset: Int64.min).description, "stack[-0x8000000000000000]")
        XCTAssertEqual(MacIRValue.immediate(-0x10).description, "-0x10")
    }

    func testMinimumSignedFieldOffsetDescribesWithoutOverflow() {
        let path = MacIRIndirectTargetResolution.FieldPath(parameter: 0, components: [Int64.min, 8])
        XCTAssertEqual(path.description, "x0-0x8000000000000000->+0x8")
    }
}

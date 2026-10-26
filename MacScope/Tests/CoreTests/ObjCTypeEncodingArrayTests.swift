import XCTest
@testable import MacScope

final class ObjCTypeEncodingArrayTests: XCTestCase {

    func testDecodesArrayExtents() {
        XCTAssertEqual(ObjCTypeEncoding.decode("[5i]"), "int[5]")
        XCTAssertEqual(ObjCTypeEncoding.decode("[16c]"), "char[16]")
        XCTAssertEqual(ObjCTypeEncoding.decode("[2[3i]]"), "int[2][3]")
        XCTAssertEqual(ObjCTypeEncoding.decode("[4^i]"), "int *[4]")
        XCTAssertEqual(ObjCTypeEncoding.decode("[3{MSPoint=ii}]"), "MSPoint[3]")
        XCTAssertEqual(ObjCTypeEncoding.decode("r[7i]"), "const int[7]")
    }

    func testDeclarationPlacesArraySuffixAfterName() {
        XCTAssertEqual(ObjCTypeEncoding.declaration(type: "char[16]", name: "buf"), "char buf[16]")
        XCTAssertEqual(ObjCTypeEncoding.declaration(type: "int *[4]", name: "p"), "int *p[4]")
        XCTAssertEqual(ObjCTypeEncoding.declaration(type: "int[2][3]", name: "m"), "int m[2][3]")
        XCTAssertEqual(ObjCTypeEncoding.declaration(type: "MSPoint[3]", name: "points"), "MSPoint points[3]")
    }

    func testNonArrayRegressionsRemainUnchanged() {
        XCTAssertEqual(ObjCTypeEncoding.decode("^i"), "int *")
        XCTAssertEqual(ObjCTypeEncoding.decode("i"), "int")
        XCTAssertEqual(ObjCTypeEncoding.decode("{MSPoint=ii}"), "MSPoint")
    }
}

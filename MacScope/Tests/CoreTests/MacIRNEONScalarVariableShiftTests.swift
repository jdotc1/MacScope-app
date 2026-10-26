import XCTest
@testable import MacScope

final class MacIRNEONScalarVariableShiftTests: XCTestCase {
    func testLowByteAndScalarComplement() throws {
        let d = try XCTUnwrap(MacIRNEONScalarVariableShift(kind: .sshl, destination: 31, source: 31, count: 31))
        XCTAssertEqual(d.evaluate(value: 0x8000000000000000, countBits: 0x123456789abcdeff).low, 0xc000000000000000)
        XCTAssertEqual(d.evaluate(value: .max, countBits: 0x100).low, .max)
        XCTAssertEqual(d.evaluate(value: .max, countBits: 63).high, 0)
        XCTAssertEqual(d.evaluate(value: .max, countBits: 64).low, 0)
    }
    func testExtremeAndRounding() throws {
        let signed = try XCTUnwrap(MacIRNEONScalarVariableShift(kind: .srshl, destination: 0, source: 1, count: 2))
        let unsigned = try XCTUnwrap(MacIRNEONScalarVariableShift(kind: .urshl, destination: 0, source: 1, count: 2))
        XCTAssertEqual(signed.evaluate(value: UInt64(bitPattern: -3), countBits: 255).low, .max)
        XCTAssertEqual(unsigned.evaluate(value: .max, countBits: 255).low, 0x8000000000000000)
        XCTAssertEqual(unsigned.evaluate(value: .max, countBits: 192).low, 1)
        XCTAssertEqual(signed.evaluate(value: .max, countBits: 192).low, 0)
        XCTAssertEqual(unsigned.evaluate(value: .max, countBits: 191).low, 0)
        XCTAssertEqual(unsigned.evaluate(value: .max, countBits: 128).low, 0)
    }
    func testInvalidPhysicalNames() {
        XCTAssertNil(MacIRNEONScalarVariableShift(kind: .ushl, destination: 32, source: 0, count: 0))
        XCTAssertNil(MacIRNEONScalarVariableShift(kind: .ushl, destination: 0, source: -1, count: 0))
        XCTAssertNil(MacIRNEONScalarVariableShift(kind: .ushl, destination: 0, source: 0, count: 32))
    }
    func testHighPhysicalRegistersDoNotCreateFormalAuthority() {
        for index in [8, 30] {
            XCTAssertNil(MacIRFunctionParameter(id: .init(rawValue: "87-high-\(index)"), bindingID: .gpr(0), sourcePosition: 0,
                abiLocation: .gpr(index: index, carrierWidth: 64), type: "uint64_t", evidence: .authoritativeUser))
        }
    }

}

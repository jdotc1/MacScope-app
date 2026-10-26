import Foundation
import XCTest
@testable import MacScope

final class MachOExceptionLSDATests: XCTestCase {
    private func parse(_ bytes: [UInt8]) throws -> MachOExceptionLSDA.Report {
        try MachOExceptionLSDA.parse(data: Data(bytes), address: 0x2000,
                                    functionStart: 0x1000, functionEnd: 0x1100)
    }

    func testCallSiteLandingPadAndZeroLanding() throws {
        let report = try parse([0xff, 0xff, 1, 8, 0, 8, 16, 0, 8, 4, 0, 0])
        XCTAssertEqual(report.callsites.count, 2)
        XCTAssertEqual(report.callsites[0].protectedRange, 0x1000..<0x1008)
        XCTAssertEqual(report.callsites[0].landingPad, 0x1010)
        XCTAssertNil(report.callsites[1].landingPad)
        XCTAssertEqual(report.callsites[0].source, 4..<8)
        XCTAssertTrue(report.actions.isEmpty)
    }

    func testActionChainAndTypeTable() throws {
        let report = try parse([0xff, 3, 14, 1, 4, 0, 8, 16, 1,
                                0, 1, 1, 0, 0x44, 0x33, 0x22, 0x11])
        XCTAssertEqual(report.callsites[0].actionChain, [9, 11])
        XCTAssertEqual(report.actions.map(\.filter), [0, 1])
        XCTAssertEqual(report.actions[0].nextOffset, 11)
        XCTAssertEqual(report.types[0].index, 1)
        XCTAssertEqual(report.types[0].pointer, .direct(0x11223344))
        XCTAssertEqual(report.types[0].source, 13..<17)
    }

    func testNegativeSpecificationIncludesTerminator() throws {
        let report = try parse([0xff, 3, 12, 1, 4, 0, 8, 16, 1,
                                0x7f, 0, 0x44, 0x33, 0x22, 0x11, 1, 0])
        XCTAssertEqual(report.actions[0].filter, -1)
        XCTAssertEqual(report.actions[0].specificationIndexes, [1])
        XCTAssertEqual(report.actions[0].specificationSource, 15..<17)
        XCTAssertEqual(report.types[0].pointer, .direct(0x11223344))
    }

    func testEmptySpecificationRetainsZeroByteProof() throws {
        let report = try parse([0xff, 3, 8, 1, 4, 0, 8, 16, 1, 0x7f, 0, 0])
        XCTAssertEqual(report.actions[0].specificationIndexes, [])
        XCTAssertEqual(report.actions[0].specificationSource, 11..<12)
    }

    func testIndirectTypeRemainsSlotAndEncodedNullRemainsNull() throws {
        let indirect = try parse([0xff, 0x9b, 12, 1, 4, 0, 8, 16, 1,
                                  1, 0, 4, 0, 0, 0])
        XCTAssertEqual(indirect.types[0].pointer, .indirectSlot(0x200f))
        let null = try parse([0xff, 0x9b, 12, 1, 4, 0, 8, 16, 1,
                             1, 0, 0, 0, 0, 0])
        XCTAssertEqual(null.types[0].pointer, .direct(0))
    }

    func testMalformedInputsRefuseWithoutPartialReport() {
        let cases: [[UInt8]] = [
            [], [0xff], [0xff, 0xff, 1, 4, 0, 8, 16],
            [0xff, 0xff, 1, 4, 0, 8, 16, 1, 0, 0x7f], // action cycle
            [0xff, 5, 12, 1, 4, 0, 8, 16, 1, 1, 0, 0, 0, 0, 0], // unsupported type
            [0xff, 3, 12, 1, 4, 0, 8, 16, 1, 0x7f, 0, 0, 0, 0, 0, 1], // missing spec terminator
            [0xff, 0xff, 1, 4, 0, 8, 0x80, 2] // incomplete action field
        ]
        for bytes in cases { XCTAssertThrowsError(try parse(bytes), "\(bytes)") }
    }

    func testHalfOpenFunctionBoundsAndOverflowRefuse() {
        XCTAssertThrowsError(try parse([0xff, 0xff, 1, 5, 0, 8, 0x80, 2, 0]))
        XCTAssertThrowsError(try MachOExceptionLSDA.parse(
            data: Data([0xff, 0xff, 1, 4, 0, 8, 16, 0]), address: UInt64.max,
            functionStart: 0x1000, functionEnd: 0x1100))
    }

    func testTruncatedAndOverflowingLEBRefuse() {
        XCTAssertThrowsError(try parse([0xff, 0xff, 1, 0x80]))
        XCTAssertThrowsError(try parse([0xff, 0xff, 1] + Array(repeating: 0xff, count: 10)))
    }
}

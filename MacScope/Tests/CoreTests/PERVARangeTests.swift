import Foundation
import XCTest
@testable import MacScope

final class PERVARangeTests: XCTestCase {
    func testSectionRangeIncludesStartAndExcludesEnd() {
        XCTAssertEqual(offset(0x1000, start: 0x1000, size: 4), 0)
        XCTAssertEqual(offset(0x1003, start: 0x1000, size: 4), 3)
        XCTAssertNil(offset(0x0FFF, start: 0x1000, size: 4))
        XCTAssertNil(offset(0x1004, start: 0x1000, size: 4))
        XCTAssertNil(offset(0x1000, start: 0x1000, size: 0))
    }

    func testSectionRangeSupportsLastRepresentableRVA() {
        XCTAssertEqual(offset(.max, start: .max - 3, size: 4), 3)
        XCTAssertEqual(offset(.max, start: .max, size: 1), 0)
        XCTAssertNil(offset(.max, start: .max - 3, size: 3))
    }

    func testSectionRangeDoesNotWrapToLowAddresses() {
        XCTAssertEqual(offset(.max, start: .max - 1, size: 4), 1)
        XCTAssertNil(offset(0, start: .max - 1, size: 4))
        XCTAssertNil(offset(1, start: .max - 1, size: 4))
    }

    func testOrdinaryPEExportRetainsNameAndAddress() throws {
        let bytes = ordinaryExportImage()
        let loaded = try PEBinaryLoader.parse(
            bytes: bytes, name: "range.exe", path: "/synthetic/range.exe"
        )
        XCTAssertEqual(loaded.exports.count, 1)
        XCTAssertEqual(loaded.exports.first?.name, "sample")
        XCTAssertEqual(loaded.exports.first?.address, 0x1_4000_2000)
        XCTAssertEqual(loaded.exports.first?.source, "export-table")
        XCTAssertEqual(loaded.sections.first?.address, 0x1_4000_1000)
        XCTAssertEqual(loaded.sections.first?.fileOffset, 0x200)
        XCTAssertEqual(loaded.bytes, bytes)
    }

    private func offset(_ rva: UInt32, start: UInt32, size: UInt32) -> UInt32? {
        PEBinaryLoader.sectionRelativeOffset(forRVA: rva, sectionStart: start, sectionSize: size)
    }

    /// A small PE32+ with one ordinary data section and one named export.
    private func ordinaryExportImage() -> Data {
        var bytes = [UInt8](repeating: 0, count: 0x400)
        func put(_ offset: Int, _ value: UInt64, width: Int = 4) {
            for index in 0..<width {
                bytes[offset + index] = UInt8(truncatingIfNeeded: value >> (index * 8))
            }
        }
        func string(_ offset: Int, _ value: String) {
            for (index, byte) in value.utf8.enumerated() { bytes[offset + index] = byte }
        }
        put(0, 0x5A4D, width: 2)
        put(0x3C, 0x80)
        put(0x80, 0x4550)
        put(0x84, 0x8664, width: 2)
        put(0x86, 1, width: 2)
        put(0x94, 0xF0, width: 2)
        put(0x96, 0x22, width: 2)
        let optional = 0x98
        put(optional, 0x20B, width: 2)
        put(optional + 24, 0x1_4000_0000, width: 8)
        put(optional + 108, 1)
        put(optional + 112, 0x1000)
        put(optional + 116, 40)
        let section = optional + 0xF0
        string(section, ".edata")
        put(section + 8, 0x200)
        put(section + 12, 0x1000)
        put(section + 16, 0x200)
        put(section + 20, 0x200)
        put(section + 36, 0x4000_0040)
        put(0x210, 1)
        put(0x214, 1)
        put(0x218, 1)
        put(0x21C, 0x1040)
        put(0x220, 0x1050)
        put(0x224, 0x1060)
        put(0x240, 0x2000)
        put(0x250, 0x1070)
        string(0x270, "sample")
        return Data(bytes)
    }
}

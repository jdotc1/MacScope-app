import Foundation
import XCTest
@testable import MacScope

/// MS-25 reader hardening: `LittleEndianReader` over a nonzero-index `Data` slice
/// and adversarial offsets. Ported from the 40 standalone checks in the
/// 2026-10-12 audit's `ReaderHarness.swift`. Every offset and limit is
/// file-relative (0 = first byte of the reader's slice); a slice whose
/// `startIndex` is above zero must read the same bytes as a rebased copy, and an
/// offset near `Int.max` must be rejected without an overflowing add.
final class LittleEndianReaderTests: XCTestCase {

    /// "hello\0world\0" behind ten 0xEE bytes, sliced so `startIndex == 10`.
    private let slice: Data = (Data(repeating: 0xEE, count: 10) + Data("hello\0world\0".utf8))[10...]

    private var reader: LittleEndianReader { LittleEndianReader(slice) }

    func testFixtureIsNonzeroIndexSlice() {
        XCTAssertEqual(slice.startIndex, 10, "fixture must be a nonzero-index Data slice")
    }

    func testCStringIsFileRelativeOnSlice() {
        XCTAssertEqual(reader.cString(fileOffset: 0, limit: slice.count), "hello", "slice string")
        XCTAssertEqual(reader.cString(fileOffset: 6, limit: slice.count), "world", "second string")
        XCTAssertEqual(reader.cString(fileOffset: 0, limit: 3), "hel", "file-relative limit")
        XCTAssertEqual(reader.cString(fileOffset: 3, limit: 3), "", "empty interval")
        XCTAssertEqual(reader.cString(fileOffset: -1, limit: 5), "", "negative offset")
        XCTAssertEqual(reader.cString(fileOffset: 0, limit: -1), "", "negative limit")
        XCTAssertEqual(reader.cString(fileOffset: Int.max, limit: Int.max), "", "huge offset")
        XCTAssertEqual(reader.cString(fileOffset: 0, limit: Int.max), "hello", "clamp huge limit")
    }

    func testByteBoundsOnSlice() {
        XCTAssertNil(reader.byte(-1), "negative byte")
        XCTAssertNil(reader.byte(Int.max), "huge byte")
        XCTAssertNil(reader.byte(slice.count), "end byte")
        XCTAssertEqual(reader.byte(0), 0x68, "slice byte")
    }

    func testIntegerAccessorsRejectInvalidOffsetsWithoutOverflow() {
        for offset in [-1, Int.max, Int.max - 7, slice.count] {
            assertTruncated("u16 invalid \(offset)") { _ = try reader.u16(offset) }
            assertTruncated("u32 invalid \(offset)") { _ = try reader.u32(offset) }
            assertTruncated("u64 invalid \(offset)") { _ = try reader.u64(offset) }
        }
    }

    func testIntegerByteOrderOnSlice() throws {
        let numbers = (Data([0xEE]) + Data([1, 2, 3, 4, 5, 6, 7, 8]))[1...]
        let little = LittleEndianReader(numbers)
        let big = LittleEndianReader(numbers, bigEndian: true)
        XCTAssertEqual(try little.u16(0), 0x0201, "little16")
        XCTAssertEqual(try big.u16(0), 0x0102, "big16")
        XCTAssertEqual(try little.u32(0), 0x0403_0201, "little32")
        XCTAssertEqual(try big.u32(0), 0x0102_0304, "big32")
        XCTAssertEqual(try little.u64(0), 0x0807_0605_0403_0201, "little64")
        XCTAssertEqual(try big.u64(0), 0x0102_0304_0506_0708, "big64")
    }

    func testRangeRejectsOverflowAndAdmitsEmptyEnd() {
        XCTAssertNil(reader.range(UInt64.max, 1), "range overflow")
        XCTAssertNil(reader.range(0, UInt64.max), "range size overflow")
        XCTAssertEqual(reader.range(UInt64(slice.count), 0), slice.count..<slice.count, "empty end range")
    }

    func testScanCStringsOnSlice() {
        var strings: [StringLiteralSummary] = []
        reader.scanCStrings(fileOffset: 0, size: slice.count, baseAddress: 0x1000, sectionName: ".rdata") {
            strings.append($0)
        }
        XCTAssertEqual(strings.map(\.value), ["hello", "world"], "slice scan")
        XCTAssertEqual(strings.map(\.address), [0x1000, 0x1006], "scan addresses")
        XCTAssertEqual(strings.map(\.byteLength), [6, 6], "scan lengths")
    }

    func testScanCStringsRejectsInvalidSpans() {
        var emitted = 0
        reader.scanCStrings(fileOffset: Int.max, size: 1, baseAddress: 0, sectionName: "") { _ in emitted += 1 }
        XCTAssertEqual(emitted, 0, "huge scan offset")
        reader.scanCStrings(fileOffset: 1, size: Int.max, baseAddress: 0, sectionName: "") { _ in emitted += 1 }
        XCTAssertEqual(emitted, 0, "huge scan length")
        reader.scanCStrings(fileOffset: -1, size: 1, baseAddress: 0, sectionName: "") { _ in emitted += 1 }
        XCTAssertEqual(emitted, 0, "negative scan")
    }

    private func assertTruncated(
        _ message: String, file: StaticString = #filePath, line: UInt = #line,
        _ body: () throws -> Void
    ) {
        do {
            try body()
            XCTFail("\(message): accepted", file: file, line: line)
        } catch BinaryReadError.truncated {
            // expected
        } catch {
            XCTFail("\(message): unexpected error \(error)", file: file, line: line)
        }
    }
}

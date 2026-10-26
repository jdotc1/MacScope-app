import Foundation
import XCTest
@testable import MacScope

final class MachOResolvedUnwindRowsTests: XCTestCase {
    private struct Page {
        let low: UInt32
        let kind: UInt32
        let entries: [(UInt32, UInt32)]
        var local: [UInt32] = []
    }

    private struct Fixture {
        var data: Data
        var section: MachOSection

        mutating func write32(_ value: UInt32, at offset: Int) {
            for byte in 0..<4 {
                data[data.startIndex + 16 + offset + byte] = UInt8(truncatingIfNeeded: value >> (byte * 8))
            }
        }

        mutating func write16(_ value: UInt16, at offset: Int) {
            for byte in 0..<2 {
                data[data.startIndex + 16 + offset + byte] = UInt8(truncatingIfNeeded: value >> (byte * 8))
            }
        }

        mutating func truncate() {
            data.removeLast()
            section.size -= 1
        }

        var rows: [MachOUnwindFunctionStarts.ResolvedRow]? {
            MachOUnwindFunctionStarts.resolvedRows(in: data, section: section)
        }
    }

    private func fixture(common: [UInt32] = [], pages: [Page], end: UInt32) -> Fixture {
        var header = Data()
        var index = Data()
        var pageBytes = Data()
        func word(_ value: UInt32, into data: inout Data) {
            for byte in 0..<4 { data.append(UInt8(truncatingIfNeeded: value >> (byte * 8))) }
        }
        func half(_ value: UInt16, into data: inout Data) {
            for byte in 0..<2 { data.append(UInt8(truncatingIfNeeded: value >> (byte * 8))) }
        }
        let indexOffset = 28 + common.count * 4
        let pagesOffset = indexOffset + (pages.count + 1) * 12
        for value: UInt32 in [1, 28, UInt32(common.count), 0, 0, UInt32(indexOffset), UInt32(pages.count + 1)] {
            word(value, into: &header)
        }
        for encoding in common { word(encoding, into: &header) }
        for page in pages {
            word(page.low, into: &index)
            word(UInt32(pagesOffset + pageBytes.count), into: &index)
            word(0, into: &index)
            word(page.kind, into: &pageBytes)
            half(page.kind == 2 ? 8 : 12, into: &pageBytes)
            half(UInt16(page.entries.count), into: &pageBytes)
            if page.kind == 3 {
                half(page.local.isEmpty ? 0 : UInt16(12 + page.entries.count * 4), into: &pageBytes)
                half(UInt16(page.local.count), into: &pageBytes)
            }
            for (offset, encoding) in page.entries {
                word(offset, into: &pageBytes)
                if page.kind == 2 { word(encoding, into: &pageBytes) }
            }
            for encoding in page.local { word(encoding, into: &pageBytes) }
        }
        word(end, into: &index)
        word(0, into: &index)
        word(0, into: &index)
        let sectionBytes = header + index + pageBytes
        return Fixture(data: Data(repeating: 0, count: 16) + sectionBytes, section: MachOSection(
            sectionName: "__unwind_info", segmentName: "__TEXT", address: 0x1000,
            size: UInt64(sectionBytes.count), fileOffset: 16, alignment: 2,
            relocationOffset: 0, relocationCount: 0, flags: 0,
            reserved1: 0, reserved2: 0, reserved3: 0
        ))
    }

    private func regular() -> Fixture {
        fixture(pages: [Page(low: 0x100, kind: 2, entries: [(0x100, 0x0400_0000), (0x110, 0x0300_002c)])], end: 0x121)
    }

    private func compressed() -> Fixture {
        fixture(common: [0x0200_2000], pages: [Page(low: 0x200, kind: 3,
            entries: [(0, 0), (0x0100_0010, 0)], local: [0x0300_0044])], end: 0x220)
    }

    func testRegularRowsRetainFinalBoundaryAndDwarfReference() throws {
        let rows = try XCTUnwrap(regular().rows)
        XCTAssertEqual(rows, [
            .init(range: 0x100..<0x110, encoding: 0x0400_0000, sourceSectionOffset: 60),
            .init(range: 0x110..<0x121, encoding: 0x0300_002c, sourceSectionOffset: 68)
        ])
        XCTAssertEqual(rows.map(\.dwarfFDESectionOffset), [nil, 0x2c])
    }

    func testCompressedRowsResolveCommonAndLocalEncodings() throws {
        let rows = try XCTUnwrap(compressed().rows)
        XCTAssertEqual(rows, [
            .init(range: 0x200..<0x210, encoding: 0x0200_2000, sourceSectionOffset: 68),
            .init(range: 0x210..<0x220, encoding: 0x0300_0044, sourceSectionOffset: 72)
        ])
        XCTAssertEqual(rows.map(\.dwarfFDESectionOffset), [nil, 0x44])
    }

    func testMixedPagesJoinRangesAtFirstLevelBoundary() throws {
        let input = fixture(common: [0x0400_0000], pages: [
            Page(low: 0x100, kind: 2, entries: [(0x100, 0x0400_0000)]),
            Page(low: 0x110, kind: 3, entries: [(0, 0)])
        ], end: 0x121)
        XCTAssertEqual(try XCTUnwrap(input.rows), [
            .init(range: 0x100..<0x110, encoding: 0x0400_0000, sourceSectionOffset: 76),
            .init(range: 0x110..<0x121, encoding: 0x0400_0000, sourceSectionOffset: 96)
        ])
    }

    func testZeroAndUnknownModesRemainRows() throws {
        let input = fixture(pages: [Page(low: 0x100, kind: 2,
            entries: [(0x100, 0), (0x110, 0x0600_0000)])], end: 0x120)
        let rows = try XCTUnwrap(input.rows)
        XCTAssertEqual(rows, [
            .init(range: 0x100..<0x110, encoding: 0, sourceSectionOffset: 60),
            .init(range: 0x110..<0x120, encoding: 0x0600_0000, sourceSectionOffset: 68)
        ])
        XCTAssertEqual(rows.map(\.dwarfFDESectionOffset), [nil, nil])
        XCTAssertEqual(MachOUnwindFunctionStarts.functionOffsets(in: input.data, section: input.section), [0x100, 0x110])
    }

    func testInvalidCompressedEncodingDeclinesWithoutChangingOffsetReader() {
        let input = fixture(common: [0x0400_0000], pages: [
            Page(low: 0x200, kind: 3, entries: [(0x0100_0000, 0)])
        ], end: 0x210)
        XCTAssertNil(input.rows)
        XCTAssertEqual(MachOUnwindFunctionStarts.functionOffsets(in: input.data, section: input.section), [0x200])
    }

    func testMissingOrInvalidSentinelDeclines() {
        for (offset, value): (Int, UInt32) in [(44, 52), (24, 1), (32, 0), (40, 0x100)] {
            var input = regular()
            input.write32(value, at: offset)
            XCTAssertNil(input.rows, "section offset \(offset)")
        }
    }

    func testUnorderedOrOutOfRangeEntriesDecline() {
        for (offset, value): (Int, UInt32) in [(60, 0x104), (68, 0x100), (68, 0x121)] {
            var input = regular()
            input.write32(value, at: offset)
            XCTAssertNil(input.rows, "section offset \(offset), value \(value)")
        }
    }

    func testTruncatedRowsAndEncodingsDecline() {
        let packedOnly = fixture(common: [0x0400_0000], pages: [
            Page(low: 0x200, kind: 3, entries: [(0, 0)])
        ], end: 0x210)
        for var input in [regular(), packedOnly, compressed()] {
            input.truncate()
            XCTAssertNil(input.rows)
        }
    }

    func testOverflowAndUnsupportedStructureDecline() {
        let overflow = fixture(common: [0x0400_0000], pages: [
            Page(low: 0xffff_fff0, kind: 3, entries: [(0x20, 0)])
        ], end: 0xffff_ffff)
        XCTAssertNil(overflow.rows)
        for (offset, value): (Int, UInt32) in [(52, 99), (0, 2), (8, 257)] {
            var input = regular()
            input.write32(value, at: offset)
            XCTAssertNil(input.rows)
        }
        var pageExtent = regular()
        pageExtent.write16(4095, at: 56)
        XCTAssertNil(pageExtent.rows)
        var overlap = compressed()
        overlap.write16(12, at: 64)
        XCTAssertNil(overlap.rows)
        var zeroFill = regular()
        zeroFill.section.flags = 1
        XCTAssertNil(zeroFill.rows)
        var stripped = regular()
        stripped.section.fileOffset = 0
        XCTAssertNil(stripped.rows)
        var outside = regular()
        outside.section.size += 1
        XCTAssertNil(outside.rows)
    }

    func testEmptyTablesHaveNoRows() {
        let sentinelOnly = fixture(pages: [], end: 0x120)
        XCTAssertEqual(sentinelOnly.rows, [])
        var noIndex = sentinelOnly
        noIndex.write32(0, at: 24)
        XCTAssertEqual(noIndex.rows, [])
    }

    func testNonzeroDataStartIndexUsesSliceRelativeOffsets() throws {
        let input = regular()
        var sliced = input
        sliced.data = (Data(repeating: 0xaa, count: 7) + input.data).dropFirst(7)
        XCTAssertEqual(sliced.data.startIndex, 7)
        XCTAssertEqual(try XCTUnwrap(sliced.rows), try XCTUnwrap(input.rows))
    }
}

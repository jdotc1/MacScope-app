import Foundation
import XCTest
@testable import MacScope

final class DyldSharedCacheBudgetTests: XCTestCase {
    func testSharedPathOffsetConsumesOneScanAndDecodeAllowance() throws {
        let bytes = pathCache(paths: [Array("/a".utf8)], pathIndexes: [0, 0, 0])
        let parser = DyldSharedCacheParser(limits: .init(
            maximumPathScanBytes: 3, maximumAggregatePathScanBytes: 3,
            maximumAggregatePathDecodedBytes: 2))
        let header = try parser.parseHeader(bytes)
        XCTAssertEqual(header.images.map(\.path), ["/a", "/a", "/a"])
        XCTAssertEqual(Set(header.images.map(\.pathFileOffset)).count, 1)
    }

    func testPathScanLimitRejectsInsteadOfTruncating() {
        let bytes = pathCache(paths: [Array("/a".utf8)], pathIndexes: [0])
        let parser = DyldSharedCacheParser(limits: .init(maximumPathScanBytes: 2))
        XCTAssertThrowsError(try parser.parseHeader(bytes)) { error in
            XCTAssertEqual(error as? DyldSharedCacheError, .malformed("image path exceeds scan budget"))
        }
    }

    func testAggregatePathScanLimitCoversDistinctOffsets() {
        let bytes = pathCache(paths: [Array("/a".utf8), Array("/b".utf8)], pathIndexes: [0, 1])
        let parser = DyldSharedCacheParser(limits: .init(maximumAggregatePathScanBytes: 5))
        XCTAssertThrowsError(try parser.parseHeader(bytes)) { error in
            XCTAssertEqual(error as? DyldSharedCacheError,
                .malformed("image paths exceed aggregate scan budget"))
        }
    }

    func testDecodedPathBudgetCountsUTF8ReplacementBytes() {
        let bytes = pathCache(paths: [[0xff], [0xfe]], pathIndexes: [0, 1])
        let parser = DyldSharedCacheParser(limits: .init(maximumAggregatePathDecodedBytes: 5))
        XCTAssertThrowsError(try parser.parseHeader(bytes)) { error in
            XCTAssertEqual(error as? DyldSharedCacheError,
                .malformed("image paths exceed decoded byte budget"))
        }
    }

    func testPerPathDecodedBudgetCountsUTF8ReplacementBytes() {
        let bytes = pathCache(paths: [[0xff]], pathIndexes: [0])
        let parser = DyldSharedCacheParser(limits: .init(maximumPathDecodedBytes: 2))
        XCTAssertThrowsError(try parser.parseHeader(bytes)) { error in
            XCTAssertEqual(error as? DyldSharedCacheError,
                .malformed("image path exceeds decoded byte budget"))
        }
    }

    func testDistinctValidPathsAtExactBudgetsRemainUnchanged() throws {
        let bytes = pathCache(paths: [Array("/a".utf8), Array("/b".utf8)], pathIndexes: [0, 1])
        let parser = DyldSharedCacheParser(limits: .init(
            maximumPathScanBytes: 3, maximumAggregatePathScanBytes: 6,
            maximumAggregatePathDecodedBytes: 4))
        let bounded = try parser.parseHeader(bytes)
        let ordinary = try DyldSharedCacheParser().parseHeader(bytes)
        XCTAssertEqual(bounded.images, ordinary.images)
        XCTAssertEqual(bounded.images.map(\.path), ["/a", "/b"])
    }

    func testProjectionBudgetIncludesInitialHeaderAndLoadCommands() {
        assertProjectionBudgetRejects(maximum: 279)
    }

    func testProjectionBudgetIncludesReplacementHeaderSegment() {
        assertProjectionBudgetRejects(maximum: 511)
    }

    func testProjectionBudgetIncludesAllSegments() {
        assertProjectionBudgetRejects(maximum: 519)
    }

    func testProjectionBudgetIsSharedBySegmentsAndLinkeditPayloads() {
        assertProjectionBudgetRejects(maximum: 523)
    }

    func testProjectionBudgetAccumulatesSeparateLinkeditPayloads() {
        assertProjectionBudgetRejects(maximum: 527)
    }

    func testValidProjectionAtExactAggregateBudgetPreservesBytesAndOffsets() throws {
        let bytes = projectionCache()
        let parser = DyldSharedCacheParser(limits: .init(maximumProjectedBytes: 528))
        let header = try parser.parseHeader(bytes)
        let image = try XCTUnwrap(header.images.first)
        let projected = try parser.projectImage(image, from: bytes, header: header)
        let ordinary = try DyldSharedCacheParser().projectImage(image, from: bytes, header: header)
        XCTAssertEqual(projected, ordinary)
        XCTAssertEqual(projected.count, 528)
        XCTAssertEqual(Array(projected[512..<528]), Array(repeating: UInt8(0x11), count: 8) + [0, 0, 0, 0, 0, 0, 0, 0])
        let reader = LittleEndianReader(projected)
        XCTAssertEqual(try reader.u64(32 + 72 + 40), 512)
        XCTAssertEqual(try reader.u32(32 + 3 * 72 + 8), 520)
        XCTAssertEqual(try reader.u32(32 + 3 * 72 + 16 + 8), 524)
    }

    private func assertProjectionBudgetRejects(
        maximum: UInt64, file: StaticString = #filePath, line: UInt = #line
    ) {
        let bytes = projectionCache()
        let parser = DyldSharedCacheParser(limits: .init(maximumProjectedBytes: maximum))
        XCTAssertThrowsError(try {
            let header = try parser.parseHeader(bytes)
            let image = try XCTUnwrap(header.images.first)
            return try parser.projectImage(image, from: bytes, header: header)
        }(), file: file, line: line) { error in
            XCTAssertEqual(error as? DyldSharedCacheError,
                .malformed("projected image exceeds aggregate byte budget"), file: file, line: line)
        }
    }

    private func pathCache(paths: [[UInt8]], pathIndexes: [Int]) -> Data {
        let imageOffset = 64
        var bytes = Data(repeating: 0, count: imageOffset + pathIndexes.count * 32)
        var pathOffsets: [UInt32] = []
        for path in paths {
            pathOffsets.append(UInt32(bytes.count))
            bytes.append(contentsOf: path)
            bytes.append(0)
        }
        putString("dyld_v1  arm64e", in: &bytes, at: 0)
        bytes.replaceUInt32LE(at: 16, with: 32)
        bytes.replaceUInt32LE(at: 20, with: 1)
        bytes.replaceUInt32LE(at: 24, with: UInt32(imageOffset))
        bytes.replaceUInt32LE(at: 28, with: UInt32(pathIndexes.count))
        bytes.replaceUInt64LE(at: 32, with: 0x1_8000_0000)
        bytes.replaceUInt64LE(at: 40, with: UInt64(bytes.count))
        bytes.replaceUInt32LE(at: 56, with: 5)
        bytes.replaceUInt32LE(at: 60, with: 5)
        for (index, pathIndex) in pathIndexes.enumerated() {
            bytes.replaceUInt64LE(at: imageOffset + index * 32, with: 0x1_8000_0000 + UInt64(index))
            bytes.replaceUInt32LE(at: imageOffset + index * 32 + 24, with: pathOffsets[pathIndex])
        }
        return bytes
    }

    private func projectionCache() -> Data {
        let base: UInt64 = 0x1_8000_0000
        var bytes = Data(repeating: 0, count: 0x1000)
        putString("dyld_v1  arm64e", in: &bytes, at: 0)
        bytes.replaceUInt32LE(at: 16, with: 0x200)
        bytes.replaceUInt32LE(at: 20, with: 1)
        bytes.replaceUInt32LE(at: 24, with: 0x220)
        bytes.replaceUInt32LE(at: 28, with: 1)
        bytes.replaceUInt64LE(at: 0x200, with: base)
        bytes.replaceUInt64LE(at: 0x208, with: UInt64(bytes.count))
        bytes.replaceUInt32LE(at: 0x218, with: 5)
        bytes.replaceUInt32LE(at: 0x21c, with: 5)
        bytes.replaceUInt64LE(at: 0x220, with: base + 0x400)
        bytes.replaceUInt32LE(at: 0x238, with: 0x240)
        putString("/usr/lib/libBudget.dylib", in: &bytes, at: 0x240)
        bytes.replaceUInt32LE(at: 0x400, with: MachOConstants.machMagic64)
        bytes.replaceUInt32LE(at: 0x404, with: 0x0100000c)
        bytes.replaceUInt32LE(at: 0x40c, with: 6)
        bytes.replaceUInt32LE(at: 0x410, with: 5)
        bytes.replaceUInt32LE(at: 0x414, with: 3 * 72 + 2 * 16)
        let segments: [(String, UInt64, UInt64)] = [("__TEXT", 0x400, 512), ("__DATA", 0x800, 8), ("__LINKEDIT", 0x900, 8)]
        for (index, segment) in segments.enumerated() {
            let command = 0x420 + index * 72
            bytes.replaceUInt32LE(at: command, with: MachOConstants.loadCommandSegment64)
            bytes.replaceUInt32LE(at: command + 4, with: 72)
            putString(segment.0, in: &bytes, at: command + 8)
            bytes.replaceUInt64LE(at: command + 24, with: base + segment.1)
            bytes.replaceUInt64LE(at: command + 32, with: segment.2)
            bytes.replaceUInt64LE(at: command + 40, with: segment.1)
            bytes.replaceUInt64LE(at: command + 48, with: segment.2)
        }
        for (index, kind) in [MachOConstants.loadCommandFunctionStarts, MachOConstants.loadCommandDyldExportsTrie].enumerated() {
            let command = 0x420 + 3 * 72 + index * 16
            bytes.replaceUInt32LE(at: command, with: kind)
            bytes.replaceUInt32LE(at: command + 4, with: 16)
            bytes.replaceUInt32LE(at: command + 8, with: UInt32(0x900 + index * 4))
            bytes.replaceUInt32LE(at: command + 12, with: 4)
        }
        bytes.replaceSubrange(0x800..<0x808, with: repeatElement(UInt8(0x11), count: 8))
        return bytes
    }

    private func putString(_ string: String, in bytes: inout Data, at offset: Int) {
        bytes.replaceSubrange(offset..<(offset + string.utf8.count), with: string.utf8)
    }
}

private extension Data {
    mutating func replaceUInt32LE(at offset: Int, with value: UInt32) {
        for index in 0..<4 { self[offset + index] = UInt8(truncatingIfNeeded: value >> (8 * index)) }
    }

    mutating func replaceUInt64LE(at offset: Int, with value: UInt64) {
        for index in 0..<8 { self[offset + index] = UInt8(truncatingIfNeeded: value >> (8 * index)) }
    }
}

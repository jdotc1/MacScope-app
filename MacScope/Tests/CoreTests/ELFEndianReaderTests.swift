import Foundation
import XCTest
@testable import MacScope

/// MS-25b: `ELFEndianReader` (ELF program-header / note parsing) over a nonzero-index `Data`
/// slice and adversarial offsets, mirroring `LittleEndianReaderTests` (#280). Every offset and
/// range is file-relative (0 = first byte of the reader's slice); a slice whose `startIndex` is
/// above zero must read the same bytes as a rebased copy, and an offset near `Int.max` must be a
/// typed `ELFProgramHeaderError.truncated`, never an overflowing add.
final class ELFEndianReaderTests: XCTestCase {

    /// Bytes 1...8 behind seven 0xEE bytes, sliced so `startIndex == 7`.
    private let slice: Data = (Data(repeating: 0xEE, count: 7) + Data([1, 2, 3, 4, 5, 6, 7, 8, 0, 0]))[7...]

    private var reader: ELFEndianReader { ELFEndianReader(bytes: slice, bigEndian: false) }

    func testFixtureIsNonzeroIndexSlice() {
        XCTAssertEqual(slice.startIndex, 7, "fixture must be a nonzero-index Data slice")
        XCTAssertEqual(Self.elfSlice.startIndex, 7, "ELF fixture must be a nonzero-index Data slice")
    }

    func testByteBoundsOnSlice() {
        XCTAssertNil(reader.byte(-1), "negative byte")
        XCTAssertNil(reader.byte(Int.max), "huge byte")
        XCTAssertNil(reader.byte(slice.count), "end byte")
        XCTAssertEqual(reader.byte(0), 1, "first slice byte, not the 0xEE prefix")
    }

    func testIntegerAccessorsRejectInvalidOffsetsWithoutOverflow() {
        for offset in [-1, Int.max, Int.max - 1, Int.max - 7, slice.count, slice.count - 1] {
            assertTruncated("u16 invalid \(offset)") { _ = try reader.u16(offset) }
        }
        for offset in [-1, Int.max, Int.max - 3, slice.count - 3] {
            assertTruncated("u32 invalid \(offset)") { _ = try reader.u32(offset) }
        }
        for offset in [-1, Int.max, Int.max - 7, slice.count - 7] {
            assertTruncated("u64 invalid \(offset)") { _ = try reader.u64(offset) }
        }
    }

    func testIntegerByteOrderOnSlice() throws {
        let big = ELFEndianReader(bytes: slice, bigEndian: true)
        XCTAssertEqual(try reader.u16(0), 0x0201, "little16")
        XCTAssertEqual(try big.u16(0), 0x0102, "big16")
        XCTAssertEqual(try reader.u32(0), 0x0403_0201, "little32")
        XCTAssertEqual(try big.u32(0), 0x0102_0304, "big32")
        XCTAssertEqual(try reader.u64(0), 0x0807_0605_0403_0201, "little64")
        XCTAssertEqual(try big.u64(0), 0x0102_0304_0506_0708, "big64")
        XCTAssertEqual(try reader.u16(slice.count - 2), 0, "last admitted u16")
    }

    func testRangeAccessorsAreFileRelativeOnSlice() throws {
        XCTAssertEqual(try reader.byteArray(in: 1..<4), [2, 3, 4], "slice bytes")
        let copy = try reader.subdata(in: 4..<8)
        XCTAssertEqual(Array(copy), [5, 6, 7, 8], "slice subdata")
        XCTAssertEqual(copy.startIndex, 0, "subdata is rebased")
        XCTAssertTrue(reader.allZero(in: 8..<10), "trailing zeros")
        XCTAssertFalse(reader.allZero(in: 7..<10), "nonzero byte in range")
        XCTAssertTrue(reader.allZero(in: 10..<10), "empty end range")

        XCTAssertFalse(reader.allZero(in: 8..<11), "past end is not 'all zero'")
        XCTAssertFalse(reader.allZero(in: (Int.max - 1)..<Int.max), "huge range")
        assertTruncated("byteArray past end") { _ = try reader.byteArray(in: 9..<11) }
        assertTruncated("byteArray huge") { _ = try reader.byteArray(in: (Int.max - 1)..<Int.max) }
        assertTruncated("subdata huge length") { _ = try reader.subdata(in: 1..<Int.max) }
    }

    /// Program headers, PT_NOTE records and the sectionless projection read from a slice must
    /// equal the same parse over a rebased copy (before MS-25b the slice trapped on `bytes[0]`).
    func testProgramHeaderParseOnSliceMatchesRebasedCopy() throws {
        let rebased = Data(Self.elfSlice)
        XCTAssertEqual(rebased.startIndex, 0)

        let fromSlice = try ELFProgramHeaderParser.parse(Self.elfSlice)
        let fromCopy = try ELFProgramHeaderParser.parse(rebased)
        XCTAssertEqual(fromSlice, fromCopy, "slice and rebased copy must parse identically")
        XCTAssertEqual(fromSlice.records.map(\.type), [1, 1, 4])
        XCTAssertEqual(fromSlice.notes.map(\.name), ["GNU"])
        XCTAssertEqual(fromSlice.notes.first.map { Array($0.descriptor) }, [0xde, 0xad, 0xbe, 0xef])
        XCTAssertEqual(try ELFProgramHeaderParser.hasDeclaredSectionTable(Self.elfSlice), false)

        let strings = try ELFProgramHeaderBinaryProjection.stringLiterals(catalog: fromSlice, bytes: Self.elfSlice)
        XCTAssertEqual(strings.map(\.value), ["hello", "world"], "PT_LOAD string scan on slice")
        XCTAssertEqual(strings.map(\.address), [0x401300, 0x401306])

        let loaded = try ELFBinaryLoader.parse(bytes: Self.elfSlice, name: "slice", path: "/tmp/slice")
        XCTAssertEqual(loaded.sections.map(\.name), ["PT_LOAD[0]", "PT_LOAD[1]"])
        XCTAssertEqual(loaded.metadata.elfGNUBuildID, "deadbeef")
    }

    /// A program-header table that claims bytes past the slice end is a typed truncation.
    func testTruncatedSliceIsTypedError() {
        let truncated = Self.elfSlice.prefix(64 + 56)
        XCTAssertEqual(truncated.startIndex, 7)
        XCTAssertThrowsError(try ELFProgramHeaderParser.parse(truncated)) { error in
            guard case .truncated = error as? ELFProgramHeaderError else {
                return XCTFail("expected .truncated, got \(error)")
            }
        }
    }

    // MARK: - Fixture

    /// Sectionless ELF64 LE: PT_LOAD R+X (4 bytes at 0x200), PT_LOAD R ("hello\0world\0" at
    /// 0x300), PT_NOTE (GNU build-id deadbeef at 0x100); behind a 7-byte prefix, then sliced.
    private static let elfSlice: Data = {
        var elf = Data(repeating: 0, count: 0x320)
        func put(_ value: UInt64, at offset: Int, width: Int) {
            for index in 0..<width { elf[offset + index] = UInt8(truncatingIfNeeded: value >> (8 * UInt64(index))) }
        }
        elf.replaceSubrange(0..<8, with: [0x7f, 0x45, 0x4c, 0x46, 2, 1, 1, 0])
        put(2, at: 16, width: 2)            // ET_EXEC
        put(183, at: 18, width: 2)          // EM_AARCH64
        put(1, at: 20, width: 4)
        put(0x400200, at: 24, width: 8)     // e_entry
        put(64, at: 32, width: 8)           // e_phoff
        put(64, at: 52, width: 2)           // e_ehsize
        put(56, at: 54, width: 2)           // e_phentsize
        put(3, at: 56, width: 2)            // e_phnum
        func header(_ index: Int, type: UInt64, flags: UInt64, offset: UInt64, address: UInt64,
                    size: UInt64, align: UInt64) {
            let base = 64 + 56 * index
            put(type, at: base, width: 4)
            put(flags, at: base + 4, width: 4)
            put(offset, at: base + 8, width: 8)
            put(address, at: base + 16, width: 8)
            put(address, at: base + 24, width: 8)
            put(size, at: base + 32, width: 8)
            put(size, at: base + 40, width: 8)
            put(align, at: base + 48, width: 8)
        }
        header(0, type: 1, flags: 5, offset: 0x200, address: 0x400200, size: 4, align: 0x1000)
        header(1, type: 1, flags: 4, offset: 0x300, address: 0x401300, size: 12, align: 0x1000)
        header(2, type: 4, flags: 4, offset: 0x100, address: 0, size: 20, align: 4)
        put(4, at: 0x100, width: 4)         // namesz
        put(4, at: 0x104, width: 4)         // descsz
        put(3, at: 0x108, width: 4)         // NT_GNU_BUILD_ID
        elf.replaceSubrange(0x10c..<0x114, with: Array("GNU\0".utf8) + [0xde, 0xad, 0xbe, 0xef])
        elf.replaceSubrange(0x200..<0x204, with: [0xc0, 0x03, 0x5f, 0xd6]) // ret
        elf.replaceSubrange(0x300..<0x30c, with: Array("hello\0world\0".utf8))
        return (Data(repeating: 0xEE, count: 7) + elf)[7...]
    }()

    private func assertTruncated(
        _ message: String, file: StaticString = #filePath, line: UInt = #line,
        _ body: () throws -> Void
    ) {
        do {
            try body()
            XCTFail("\(message): accepted", file: file, line: line)
        } catch ELFProgramHeaderError.truncated {
            // expected
        } catch {
            XCTFail("\(message): unexpected error \(error)", file: file, line: line)
        }
    }
}

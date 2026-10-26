import Foundation
import XCTest
@testable import MacScope

final class MachOExceptionUnwindRowsTests: XCTestCase {
    private struct Fixture {
        var bytes: Data
        var section: MachOSection

        mutating func word(_ value: UInt32, at offset: Int) {
            for byte in 0..<4 {
                bytes[16 + offset + byte] = UInt8(truncatingIfNeeded: value >> (8 * byte))
            }
        }

        var rows: [MachOUnwindFunctionStarts.ResolvedRow]? {
            MachOUnwindFunctionStarts.resolvedRows(in: bytes, section: section)
        }
    }

    private func fixture(compressed: Bool = false) -> Fixture {
        var words: [UInt32] = [
            1, 0, 0, 28, 1, 32, 2,
            UInt32(bitPattern: -32),
            0x100, 64, 56,
            0x120, 0, 64,
            0x100, 0x200
        ]
        if compressed {
            // Page-local encodings; the second row is a continuation without its own LSDA.
            words += [3, 0x0002_000c, 0x0002_0014,
                      0, 0x0100_0010, 0x5400_0000, 0x8400_0000]
        } else {
            words += [2, 0x0002_0008,
                      0x100, 0x5400_0000, 0x110, 0x8400_0000]
        }
        var bytes = Data(repeating: 0, count: 16)
        for value in words {
            for byte in 0..<4 { bytes.append(UInt8(truncatingIfNeeded: value >> (8 * byte))) }
        }
        let section = MachOSection(sectionName: "__unwind_info", segmentName: "__TEXT",
            address: 0x1000, size: UInt64(bytes.count - 16), fileOffset: 16,
            alignment: 2, relocationOffset: 0, relocationCount: 0, flags: 0,
            reserved1: 0, reserved2: 0, reserved3: 0)
        return Fixture(bytes: bytes, section: section)
    }

    func testRegularAndCompressedRowsRetainExactAssociationEvidence() throws {
        for compressed in [false, true] {
            let rows = try XCTUnwrap(fixture(compressed: compressed).rows)
            XCTAssertEqual(rows.count, 2)
            XCTAssertEqual(rows[0].range, 0x100..<0x110)
            XCTAssertEqual(rows[0].functionStartOffset, 0x100)
            XCTAssertFalse(rows[0].isFunctionContinuation)
            XCTAssertEqual(rows[0].lsdaImageOffset, 0x200)
            XCTAssertEqual(rows[0].lsdaSourceSectionRange, 56..<64)
            XCTAssertEqual(rows[0].personalitySlotImageOffset, -32)
            XCTAssertEqual(rows[0].personalitySourceSectionRange, 28..<32)
            XCTAssertEqual(rows[1].range, 0x110..<0x120)
            XCTAssertTrue(rows[1].isFunctionContinuation)
            XCTAssertEqual(rows[1].functionStartOffset, 0x100)
            XCTAssertNil(rows[1].lsdaImageOffset)
            XCTAssertNil(rows[1].personalitySlotImageOffset)
        }
    }

    func testLSDAFlagRequiresAnExactUniqueAssociation() {
        for (offset, value): (Int, UInt32) in [
            (56, 0x104), // No exact compact row at this address.
            (56, 0x120), // Outside this first-level index range.
            (60, 0), // No LSDA address.
            (76, 0x1400_0000), // LSDA table entry with no HAS_LSDA flag.
            (40, 64) // HAS_LSDA flag with an empty LSDA table.
        ] {
            var input = fixture()
            input.word(value, at: offset)
            XCTAssertNil(input.rows, "section offset \(offset)")
        }
    }

    func testOrphanContinuationAndInvalidPersonalityRefuse() {
        for encoding: UInt32 in [0xd400_0000, 0x6400_0000] {
            var input = fixture()
            input.word(encoding, at: 76)
            XCTAssertNil(input.rows)
        }
    }

    func testTruncatedAssociationBytesRefuseWithoutPartialRows() {
        var input = fixture()
        input.bytes.removeLast()
        input.section.size -= 1
        XCTAssertNil(input.rows)
    }
}

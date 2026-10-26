import Foundation
import XCTest
@testable import MacScope

final class DWARFExceptionMetadataTests: XCTestCase {
    func testExactCIEAssociationRetainsIndirectPersonalityAndLSDAFields() throws {
        let input = fixture()
        let table = try decode(input.bytes)
        let cie = try XCTUnwrap(table.cies.first)
        let fde = try XCTUnwrap(table.fdes.first)
        XCTAssertEqual(fde.cieSectionOffset, cie.sectionOffset)
        XCTAssertEqual(fde.initialLocation, 0x4000)
        XCTAssertEqual(fde.rangeSize, 0x40)
        XCTAssertEqual(cie.lsdaPointerEncoding, 0x1b)
        let personality = try XCTUnwrap(cie.personalityPointer)
        XCTAssertEqual(personality.value, 0x5000)
        XCTAssertEqual(personality.encoding, 0x9b)
        XCTAssertTrue(personality.isIndirect)
        XCTAssertEqual(personality.sectionRange, input.personalityField..<(input.personalityField + 4))
        let lsda = try XCTUnwrap(fde.lsdaPointer)
        XCTAssertEqual(lsda.value, 0x6000)
        XCTAssertFalse(lsda.isIndirect)
        XCTAssertEqual(lsda.sectionRange, input.lsdaField..<(input.lsdaField + 4))
        XCTAssertEqual(cie.exceptionMetadataRange, 0..<cie.initialProgram.sectionOffset)
        XCTAssertEqual(fde.exceptionMetadataRange, input.fdeStart..<fde.program.sectionOffset)
    }

    func testSignedBackwardPersonalityAndNullLSDADoNotInventTargets() throws {
        var input = fixture(personalityAddress: 0x800)
        input.bytes.replaceSubrange(input.lsdaField..<(input.lsdaField + 4), with: [0, 0, 0, 0])
        let table = try decode(input.bytes)
        XCTAssertEqual(table.cies.first?.personalityPointer?.value, 0x800)
        XCTAssertEqual(table.fdes.first?.lsdaPointer?.value, 0)
        XCTAssertEqual(table.fdes.first?.lsdaPointer?.isIndirect, false)
    }

    func testDirectPersonalityRemainsDistinctFromIndirectSlot() throws {
        var input = fixture()
        input.bytes[input.personalityField - 1] = 0x1b
        let personality = try XCTUnwrap(decode(input.bytes).cies.first?.personalityPointer)
        XCTAssertEqual(personality.value, 0x5000)
        XCTAssertFalse(personality.isIndirect)
    }

    func testAuditAPIKeepsExistingMetadataContract() throws {
        let input = fixture()
        let reader = DWARFReader(sections: .init(ehFrame: Data(input.bytes)))
        let table = try reader.recoverStructuredCallFrameInfo(sectionAddress: 0x1000)
        XCTAssertEqual(table.fdes.first?.initialLocation, 0x4000)
        XCTAssertNil(table.cies.first?.personalityPointer)
        XCTAssertNil(table.cies.first?.lsdaPointerEncoding)
        XCTAssertNil(table.cies.first?.exceptionMetadataRange)
        XCTAssertNil(table.fdes.first?.lsdaPointer)
        XCTAssertNil(table.fdes.first?.exceptionMetadataRange)
    }

    func testMalformedAssociationTruncationAndUnsupportedEncodingRefuse() throws {
        let input = fixture()
        var dangling = input.bytes
        dangling.replaceSubrange((input.fdeStart + 4)..<(input.fdeStart + 8), with: [1, 0, 0, 0])
        var unsupported = input.bytes
        unsupported[input.personalityField - 1] = 0x3b
        var negativeRange = input.bytes
        negativeRange.replaceSubrange((input.fdeStart + 12)..<(input.fdeStart + 16),
                                      with: [0xff, 0xff, 0xff, 0xff])
        for bytes in [dangling, unsupported, negativeRange, Array(input.bytes.dropLast())] {
            XCTAssertThrowsError(try decode(bytes))
        }
    }

    func testUnsignedPCRelativeDisplacementCannotWrapIntoBackwardAddress() throws {
        var input = fixture()
        input.bytes[input.personalityField - 1] = 0x93
        input.bytes.replaceSubrange(input.personalityField..<(input.personalityField + 4),
                                    with: [0xff, 0xff, 0xff, 0xff])
        let pointer = try XCTUnwrap(decode(input.bytes).cies.first?.personalityPointer)
        XCTAssertEqual(pointer.value, 0x1000 + UInt64(input.personalityField) + UInt64(UInt32.max))
        XCTAssertThrowsError(try DWARFReader(sections: .init(ehFrame: Data(input.bytes)))
            .recoverExceptionCallFrameInfo(sectionAddress: UInt64.max - 8))
    }

    private func decode(_ bytes: [UInt8]) throws -> DWARFStructuredCallFrameTable {
        try DWARFReader(sections: .init(ehFrame: Data(bytes)))
            .recoverExceptionCallFrameInfo(sectionAddress: 0x1000)
    }

    private struct Fixture {
        var bytes: [UInt8]
        var personalityField: Int
        var fdeStart: Int
        var lsdaField: Int
    }

    private func fixture(personalityAddress: Int64 = 0x5000) -> Fixture {
        // zPLR: indirect PC-relative personality, PC-relative LSDA and FDE.
        var cie: [UInt8] = [0, 0, 0, 0, 1, 0x7a, 0x50, 0x4c, 0x52, 0, 1, 0x78, 30, 7, 0x9b]
        let personalityField = 4 + cie.count
        cie += littleEndian(personalityAddress - (0x1000 + Int64(personalityField)))
        cie += [0x1b, 0x1b, 0x0c, 31, 0]
        var bytes = littleEndian(Int64(cie.count)) + cie
        let fdeStart = bytes.count
        var fde = littleEndian(Int64(fdeStart + 4))
        fde += littleEndian(0x4000 - (0x1000 + Int64(fdeStart + 8)))
        fde += littleEndian(0x40)
        fde += [4]
        let lsdaField = fdeStart + 4 + fde.count
        fde += littleEndian(0x6000 - (0x1000 + Int64(lsdaField)))
        fde += [0]
        bytes += littleEndian(Int64(fde.count)) + fde
        return Fixture(bytes: bytes, personalityField: personalityField,
                       fdeStart: fdeStart, lsdaField: lsdaField)
    }

    private func littleEndian(_ value: Int64) -> [UInt8] {
        (0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
    }
}

import Foundation
import XCTest
@testable import MacScope

final class DWARFStructuredCFITests: XCTestCase {
    func testExactOffsetsAndLosslessOperands() throws {
        let bytes: [UInt8] = [0x41, 0x9e, 1, 0x0d, 29, 0]
        let reader = DWARFReader(sections: .init(ehFrame: fixture(program: bytes)))
        let table = try reader.recoverStructuredCallFrameInfo()
        XCTAssertEqual(table.cies.count, 1)
        XCTAssertEqual(table.fdes.count, 1)
        let cie = try XCTUnwrap(table.cies.first)
        let fde = try XCTUnwrap(table.fdes.first)
        XCTAssertEqual(cie.sectionOffset, 0)
        XCTAssertEqual(cie.initialProgram.sectionOffset, 17)
        XCTAssertEqual(cie.initialProgram.status, .complete)
        XCTAssertEqual(cie.augmentation, "zR")
        XCTAssertEqual(cie.augmentationData, [0])
        XCTAssertEqual(cie.codeAlignmentFactor, 1)
        XCTAssertEqual(cie.dataAlignmentFactor, -8)
        XCTAssertEqual(cie.returnAddressRegister, 30)
        XCTAssertEqual(fde.sectionOffset, 20)
        XCTAssertEqual(fde.cieSectionOffset, 0)
        XCTAssertEqual(fde.initialLocation, 0x1000)
        XCTAssertEqual(fde.rangeSize, 0x20)
        XCTAssertEqual(fde.program.sectionOffset, 45)
        XCTAssertEqual(fde.program.status, .complete)
        XCTAssertEqual(fde.program.rawBytes, bytes)
        XCTAssertEqual(fde.program.operations.map(\.sectionOffset), [45, 46, 48, 50])
        XCTAssertEqual(fde.program.operations.map(\.opcode), [0x41, 0x9e, 0x0d, 0])
        XCTAssertEqual(fde.program.operations.map(\.operands), [
            [.unsigned(1)], [.unsigned(30), .unsigned(1)], [.unsigned(29)], []
        ])
        XCTAssertEqual(fde.program.operations.flatMap(\.rawBytes), bytes)
        XCTAssertEqual(try reader.recoverCallFrameInfo().first?.operations, [
            "advance 1", "offset reg30 -8", "def_cfa_register reg29", "nop"
        ])
    }

    func testPCRelativePointersUseSectionAddress() throws {
        let data = fixture(program: [], encoding: 0x10,
                           location: UInt64(bitPattern: Int64(-0x100)))
        let table = try DWARFReader(sections: .init(ehFrame: data))
            .recoverStructuredCallFrameInfo(sectionAddress: 0x2000)
        let fde = try XCTUnwrap(table.fdes.first)
        XCTAssertEqual(fde.initialLocation, 0x1f1c)
        XCTAssertEqual(fde.rangeSize, 0x20)
        XCTAssertEqual(fde.sectionOffset, 20)
    }

    func testUnknownProgramRetainsSuffixAndCannotBeComplete() throws {
        let bytes: [UInt8] = [0x0c, 31, 0, 0x3f, 0]
        let table = try DWARFReader(sections: .init(ehFrame: fixture(program: bytes)))
            .recoverStructuredCallFrameInfo()
        let program = try XCTUnwrap(table.fdes.first?.program)
        XCTAssertEqual(program.rawBytes, bytes)
        XCTAssertEqual(program.status, .unsupported(opcode: 0x3f))
        XCTAssertEqual(program.operations.map(\.opcode), [0x0c, 0x3f])
        XCTAssertEqual(program.operations.last?.rawBytes, [0x3f])
    }

    func testMalformedProgramReportsExactInstructionOffset() throws {
        let bytes: [UInt8] = [0x0d, 0x80]
        let table = try DWARFReader(sections: .init(ehFrame: fixture(program: bytes)))
            .recoverStructuredCallFrameInfo()
        let program = try XCTUnwrap(table.fdes.first?.program)
        XCTAssertEqual(program.status, .malformed(offset: 45))
        XCTAssertEqual(program.operations, [])
        XCTAssertEqual(program.rawBytes, bytes)
        let malformedCIE = try DWARFReader(sections: .init(
            ehFrame: fixture(program: [], initialProgram: [0x0c, 31])))
            .recoverStructuredCallFrameInfo()
        XCTAssertEqual(malformedCIE.cies.first?.initialProgram.status, .malformed(offset: 17))
        XCTAssertEqual(malformedCIE.cies.first?.initialProgram.rawBytes, [0x0c, 31])
        XCTAssertEqual(malformedCIE.fdes.first?.program.status, .complete)
    }

    func testSignedAndBlockOperandsRemainLossless() throws {
        let bytes: [UInt8] = [0x11, 19, 0x7d, 0x10, 30, 2, 0x9c, 0]
        let table = try DWARFReader(sections: .init(ehFrame: fixture(program: bytes)))
            .recoverStructuredCallFrameInfo()
        let program = try XCTUnwrap(table.fdes.first?.program)
        XCTAssertEqual(program.status, .complete)
        XCTAssertEqual(program.operations.map(\.operands), [
            [.unsigned(19), .signed(-3)], [.unsigned(30), .block([0x9c, 0])]
        ])
        XCTAssertEqual(program.operations.flatMap(\.rawBytes), bytes)
    }

    func testMalformedEnvelopesThrow() throws {
        let oversized = Data([0x20, 0, 0, 0])
        var dangling = fixture(program: [])
        dangling.replaceSubrange(24..<28, with: [0xff, 0, 0, 0])
        for bytes in [oversized, Data([1]), Data([0, 0, 0, 0, 1]), dangling] {
            XCTAssertThrowsError(try DWARFReader(sections: .init(ehFrame: bytes))
                .recoverStructuredCallFrameInfo())
        }
        let empty = try DWARFReader(sections: .init()).recoverStructuredCallFrameInfo()
        XCTAssertEqual(empty.cies, [])
        XCTAssertEqual(empty.fdes, [])
        XCTAssertEqual(try DWARFReader(sections: .init(ehFrame: oversized)).recoverCallFrameInfo(), [])
    }

    private func fixture(
        program: [UInt8], encoding: UInt8 = 0, location: UInt64 = 0x1000,
        initialProgram: [UInt8] = [0x0c, 31, 0]
    ) -> Data {
        let cie = littleEndian(0, count: 4) + [1, 0x7a, 0x52, 0, 1, 0x78, 30, 1, encoding]
            + initialProgram
        var bytes = littleEndian(UInt64(cie.count), count: 4) + cie
        let pointer = UInt64(bytes.count + 4)
        let fde = littleEndian(pointer, count: 4) + littleEndian(location, count: 8)
            + littleEndian(0x20, count: 8) + [0] + program
        bytes += littleEndian(UInt64(fde.count), count: 4) + fde
        return Data(bytes)
    }

    private func littleEndian(_ value: UInt64, count: Int) -> [UInt8] {
        (0..<count).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
    }
}

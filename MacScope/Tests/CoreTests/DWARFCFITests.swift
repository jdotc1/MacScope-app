import Foundation
import XCTest
@testable import MacScope

final class DWARFCFITests: XCTestCase {
    func testPackage05FixtureRecoversFDEProgramsInSectionOrder() throws {
        let fdes = try DWARFReader(sections: try Package05DWARFFixture.sections()).recoverCallFrameInfo()

        XCTAssertEqual(fdes.count, 2)
        guard fdes.count == 2 else { return }
        XCTAssertEqual(fdes.map(\.rangeSize), [0x44, 0x58])
        XCTAssertEqual(fdes.first?.cie.version, 1)
        XCTAssertEqual(fdes.first?.cie.augmentation, "zR")
        XCTAssertEqual(fdes.first?.cie.codeAlignmentFactor, 1)
        XCTAssertEqual(fdes.first?.cie.dataAlignmentFactor, -8)
        XCTAssertEqual(fdes.first?.cie.returnAddressRegister, 30)
        XCTAssertEqual(fdes.first?.cie.fdePointerEncoding, 0x10)
        XCTAssertEqual(fdes.first?.cie.initialInstructions, ["def_cfa reg31 0"])

        XCTAssertEqual(fdes[0].operations, [
            "advance 4",
            "def_cfa_offset 48",
            "advance 12",
            "def_cfa reg29 16",
            "offset reg30 -8",
            "offset reg29 -16",
            "offset reg19 -24",
            "offset reg20 -32",
            "offset reg21 -40",
            "offset reg22 -48",
            "advance 36",
            "def_cfa reg31 48",
            "advance 12",
            "def_cfa_offset 0",
            "restore reg30",
            "restore reg29",
            "restore reg19",
            "restore reg20",
            "restore reg21",
            "restore reg22",
            "nop",
            "nop",
            "nop"
        ])
        XCTAssertEqual(fdes[1].operations, [
            "advance 4",
            "def_cfa_offset 48",
            "advance 12",
            "def_cfa reg29 16",
            "offset reg30 -8",
            "offset reg29 -16",
            "offset reg19 -24",
            "offset reg20 -32",
            "offset reg21 -40",
            "offset reg22 -48",
            "advance 56",
            "def_cfa reg31 48",
            "advance 12",
            "def_cfa_offset 0",
            "restore reg30",
            "restore reg29",
            "restore reg19",
            "restore reg20",
            "restore reg21",
            "restore reg22",
            "nop",
            "nop",
            "nop",
            "nop",
            "nop",
            "nop",
            "nop"
        ])
    }

    func testSyntheticCFIAlignsOperandsAndStopsUnknownProgramSafely() throws {
        let fdes = try DWARFReader(sections: SyntheticCFIDWARF.sections()).recoverCallFrameInfo()

        XCTAssertEqual(fdes.count, 1)
        guard fdes.count == 1 else { return }
        XCTAssertEqual(fdes[0].initialLocation, 0x1000)
        XCTAssertEqual(fdes[0].rangeSize, 0x20)
        XCTAssertEqual(fdes[0].cie.initialInstructions, ["def_cfa reg31 0"])
        XCTAssertEqual(fdes[0].operations, [
            "advance 6",
            "offset reg5 -8",
            "advance 4",
            "offset reg6 -12",
            "offset reg7 12",
            "def_cfa reg8 16",
            "def_cfa_register reg9",
            "def_cfa_offset 24",
            "undefined reg10",
            "same_value reg11",
            "remember_state",
            "restore_state"
        ])
    }

    func testMalformedCFIStopsWithoutThrowing() throws {
        let sections = DWARFReader.Sections(ehFrame: Data([0x20, 0x00, 0x00, 0x00]))
        XCTAssertEqual(try DWARFReader(sections: sections).recoverCallFrameInfo(), [])
    }
}

private enum Package05DWARFFixture {
    static func sections() throws -> DWARFReader.Sections {
        let dir = try sectionsDirectory()
        return DWARFReader.Sections(ehFrame: try load("eh_frame", from: dir))
    }

    private static func load(_ name: String, from dir: URL) throws -> Data {
        try Data(contentsOf: dir.appendingPathComponent("\(name).bin"))
    }

    private static func sectionsDirectory() throws -> URL {
        var candidate = TestSourceRoot.fileURL(#filePath).deletingLastPathComponent()
        let fileManager = FileManager.default

        while candidate.path != "/" {
            let sections = candidate
                .appendingPathComponent("handoff_package", isDirectory: true)
                .appendingPathComponent("sections", isDirectory: true)
            if fileManager.fileExists(atPath: sections.appendingPathComponent("eh_frame.bin").path) {
                return sections
            }
            candidate.deleteLastPathComponent()
        }

        throw XCTSkip("handoff_package/sections fixture is unavailable")
    }
}

private enum SyntheticCFIDWARF {
    static func sections() -> DWARFReader.Sections {
        DWARFReader.Sections(ehFrame: ehFrame())
    }

    private static func ehFrame() -> Data {
        var section: [UInt8] = []
        let cieOffset = section.count

        var cieContent = CFIBytes.u32(0)
        cieContent.append(0x01)
        cieContent += CFIBytes.cString("zR")
        cieContent += CFIBytes.uleb(2)
        cieContent += CFIBytes.sleb(-4)
        cieContent.append(30)
        cieContent += CFIBytes.uleb(1)
        cieContent.append(0x00)
        cieContent.append(0x0c)
        cieContent += CFIBytes.uleb(31)
        cieContent += CFIBytes.uleb(0)
        section += CFIBytes.entry(cieContent)

        let fdeStart = section.count
        let ciePointerFieldOffset = fdeStart + 4
        var fdeContent = CFIBytes.u32(UInt32(ciePointerFieldOffset - cieOffset))
        fdeContent += CFIBytes.u64(0x1000)
        fdeContent += CFIBytes.u64(0x20)
        fdeContent += CFIBytes.uleb(0)
        fdeContent.append(0x43)
        fdeContent.append(0x85)
        fdeContent += CFIBytes.uleb(2)
        fdeContent.append(0x02)
        fdeContent.append(0x02)
        fdeContent.append(0x05)
        fdeContent += CFIBytes.uleb(6)
        fdeContent += CFIBytes.uleb(3)
        fdeContent.append(0x11)
        fdeContent += CFIBytes.uleb(7)
        fdeContent += CFIBytes.sleb(-3)
        fdeContent.append(0x0c)
        fdeContent += CFIBytes.uleb(8)
        fdeContent += CFIBytes.uleb(16)
        fdeContent.append(0x0d)
        fdeContent += CFIBytes.uleb(9)
        fdeContent.append(0x0e)
        fdeContent += CFIBytes.uleb(24)
        fdeContent.append(0x07)
        fdeContent += CFIBytes.uleb(10)
        fdeContent.append(0x08)
        fdeContent += CFIBytes.uleb(11)
        fdeContent.append(0x0a)
        fdeContent.append(0x0b)
        fdeContent.append(0x3f)
        fdeContent.append(0x00)
        section += CFIBytes.entry(fdeContent)

        return Data(section)
    }
}

private enum CFIBytes {
    static func entry(_ content: [UInt8]) -> [UInt8] {
        u32(UInt32(content.count)) + content
    }

    static func cString(_ string: String) -> [UInt8] {
        Array(string.utf8) + [0x00]
    }

    static func u32(_ value: UInt32) -> [UInt8] {
        (0..<4).map { UInt8((value >> (8 * $0)) & 0xff) }
    }

    static func u64(_ value: UInt64) -> [UInt8] {
        (0..<8).map { UInt8((value >> (8 * $0)) & 0xff) }
    }

    static func uleb(_ value: UInt64) -> [UInt8] {
        var value = value
        var bytes: [UInt8] = []
        repeat {
            var byte = UInt8(value & 0x7f)
            value >>= 7
            if value != 0 {
                byte |= 0x80
            }
            bytes.append(byte)
        } while value != 0
        return bytes
    }

    static func sleb(_ value: Int64) -> [UInt8] {
        var value = value
        var bytes: [UInt8] = []
        var more = true
        while more {
            var byte = UInt8(truncatingIfNeeded: value) & 0x7f
            let signBitSet = (byte & 0x40) != 0
            value >>= 7
            if (value == 0 && !signBitSet) || (value == -1 && signBitSet) {
                more = false
            } else {
                byte |= 0x80
            }
            bytes.append(byte)
        }
        return bytes
    }
}

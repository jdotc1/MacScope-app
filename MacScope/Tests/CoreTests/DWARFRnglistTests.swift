import Foundation
import XCTest
@testable import MacScope

final class DWARFRnglistTests: XCTestCase {
    func testPackage06FixtureRecoversLexicalBlockRanges() throws {
        let rnglists = try DWARFReader(sections: try Package06DWARFFixture.sections()).recoverRnglists()

        XCTAssertEqual(rnglists.map { Self.render($0.ranges) }, [
            "0x10-0x54;0x68-0x7c"
        ])
    }

    func testSyntheticRnglistsDecodeRangeFormsAndStopSafely() throws {
        let reader = DWARFReader(sections: SyntheticRnglistDWARF.sections())
        let rendered = try reader.recoverRnglists().map { Self.render($0.ranges) }

        XCTAssertEqual(rendered, [
            "0x1001-0x1005;0x2000-0x2010;0x2010-0x2018;0x3010-0x3018;0x4000-0x4010;0x4020-0x4025",
            "0x0-0x4",
            "0x20-0x24"
        ])
        XCTAssertEqual(try reader.recoverLoclists(), [])
        XCTAssertEqual(try reader.recoverCallFrameInfo(), [])
    }

    func testCompilationUnitBaseAppliesToOffsetPairsAndExplicitBasesOverrideIt() throws {
        for indexedBase in [false, true] {
            let reader = DWARFReader(sections: SyntheticRnglistDWARF.cuBaseSections(indexed: indexedBase))
            XCTAssertEqual(try reader.recoverRnglists().map { Self.render($0.ranges) }, [
                "0x401000-0x401006;0x40100c-0x40100f",
                "0x401000-0x401006;0x40100c-0x40100f",
                "0x0-0x6;0xc-0xf",
                "0x6000-0x6006"
            ], "indexed CU low_pc: \(indexedBase)")
        }
    }

    func testFourByteIndexedCompilationUnitRangeBaseUsesAddressTableWidth() throws {
        let reader = DWARFReader(sections: SyntheticRnglistDWARF.cuBaseSections(indexed: true, addressSize: 4))
        XCTAssertEqual(try reader.recoverRnglists().map { Self.render($0.ranges) }, [
            "0x401000-0x401006;0x40100c-0x40100f",
            "0x401000-0x401006;0x40100c-0x40100f",
            "0x0-0x6;0xc-0xf",
            "0x6000-0x6006"
        ])
    }

    private static func render(_ ranges: [DWARFRnglistRange]) -> String {
        ranges.map { range in
            "\(String(format: "0x%llx", range.lowPC))-\(String(format: "0x%llx", range.highPC))"
        }.joined(separator: ";")
    }
}

private enum Package06DWARFFixture {
    static func sections() throws -> DWARFReader.Sections {
        let dir = try sectionsDirectory()
        func load(_ name: String) throws -> Data {
            try Data(contentsOf: dir.appendingPathComponent("\(name).bin"))
        }

        return DWARFReader.Sections(
            debugInfo: try load("debug_info"),
            debugAbbrev: try load("debug_abbrev"),
            debugStr: try load("debug_str"),
            debugStrOffsets: try load("debug_str_offs"),
            debugAddr: try load("debug_addr"),
            debugLine: try load("debug_line"),
            debugLineStr: try load("debug_line_str"),
            debugRnglists: try load("debug_rnglists")
        )
    }

    private static func sectionsDirectory() throws -> URL {
        var candidate = TestSourceRoot.fileURL(#filePath).deletingLastPathComponent()
        let fileManager = FileManager.default

        while candidate.path != "/" {
            let sections = candidate
                .appendingPathComponent("handoff_package", isDirectory: true)
                .appendingPathComponent("sections", isDirectory: true)
            if fileManager.fileExists(atPath: sections.appendingPathComponent("debug_rnglists.bin").path) {
                return sections
            }
            candidate.deleteLastPathComponent()
        }

        throw XCTSkip("handoff_package/sections fixture is unavailable")
    }
}

private enum SyntheticRnglistDWARF {
    static func cuBaseSections(indexed: Bool, addressSize: UInt8 = 8) -> DWARFReader.Sections {
        func address(_ value: UInt64) -> [UInt8] {
            var bytes: [UInt8] = []
            bytes.appendU64(value)
            return Array(bytes.prefix(Int(addressSize)))
        }
        // Independently hand-encoded offset_pair(start, end), twice, then end.
        let pairs: [UInt8] = [0x04, 0x00, 0x06, 0x04, 0x0c, 0x0f, 0x00]
        let lists = [
            pairs,
            [0x05] + address(0x401000) + pairs,
            [0x05] + address(0) + pairs,
            [0x06] + address(0x6000) + address(0x6006) + [0x00]
        ]
        var abbreviations: [UInt8] = []
        appendAbbrev(code: 1, tag: 0x11, hasChildren: true, attributes: [
            (0x11, indexed ? 0x29 : 0x01), // low_pc: addrx1 or addr
            (0x73, 0x17),                 // addr_base deliberately follows low_pc
            (0x74, 0x17)                  // rnglists_base
        ], to: &abbreviations)
        appendAbbrev(code: 2, tag: 0x0b, hasChildren: false, attributes: [
            (0x11, 0x01), // child low_pc must not override the CU base
            (0x55, 0x23)
        ], to: &abbreviations)
        abbreviations.append(0)

        var die: [UInt8] = [1]
        die += indexed ? [0] : address(0x401000)
        die.appendU32(16)
        die.appendU32(12)
        for index in lists.indices {
            die.append(2)
            die += address(0x900000)
            die.appendULEB128(UInt64(index))
        }
        die.append(0)
        var addresses = [UInt8](repeating: 0, count: 16)
        addresses.replaceSubrange(8..<8+Int(addressSize), with: address(0x900000))
        addresses += address(0x401000)
        return assembleInfo(abbrev: abbreviations, die: die,
                            debugAddr: Data(addresses),
                            debugRnglists: makeRnglistsSection(lists: lists, addressSize: addressSize),
                            addressSize: addressSize)
    }

    static func sections() -> DWARFReader.Sections {
        let lists = [richList(), unknownList(), truncatedList(), directOffsetList()]
        let directOffset = absoluteListOffsets(lists)[3]

        var builder = DIEBuilder()
        builder.append(0x01)
        builder.appendU32(0x0c)
        builder.appendU32(0x08)

        appendIndexedRangeDie(index: 0, to: &builder)
        appendIndexedRangeDie(index: 1, to: &builder)
        appendIndexedRangeDie(index: 2, to: &builder)
        appendDirectRangeDie(offset: directOffset, to: &builder)
        builder.append(0x00)

        return assembleInfo(
            abbrev: abbrev(),
            die: builder.bytes,
            debugAddr: debugAddr(),
            debugRnglists: makeRnglistsSection(lists: lists)
        )
    }

    private static func appendIndexedRangeDie(index: UInt64, to builder: inout DIEBuilder) {
        builder.append(0x02)
        builder.appendULEB128(index)
    }

    private static func appendDirectRangeDie(offset: UInt32, to builder: inout DIEBuilder) {
        builder.append(0x03)
        builder.appendU32(offset)
    }

    private static func richList() -> [UInt8] {
        [0x01] + uleb(0) +
            [0x04] + uleb(1) + uleb(5) +
            [0x02] + uleb(1) + uleb(2) +
            [0x03] + uleb(2) + uleb(8) +
            [0x05] + address(0x3000) +
            [0x04] + uleb(0x10) + uleb(0x18) +
            [0x06] + address(0x4000) + address(0x4010) +
            [0x07] + address(0x4020) + uleb(5) +
            [0x00]
    }

    private static func unknownList() -> [UInt8] {
        [0x04] + uleb(0) + uleb(4) +
            [0xff] +
            [0x04] + uleb(4) + uleb(8) +
            [0x00]
    }

    private static func truncatedList() -> [UInt8] {
        [0x06] + address(0x5000)
    }

    private static func directOffsetList() -> [UInt8] {
        [0x04] + uleb(0x20) + uleb(0x24) + [0x00]
    }

    private static func debugAddr() -> Data {
        var bytes = [UInt8](repeating: 0, count: 8)
        bytes.appendU64(0x1000)
        bytes.appendU64(0x2000)
        bytes.appendU64(0x2010)
        return Data(bytes)
    }

    private static func makeRnglistsSection(lists: [[UInt8]], addressSize: UInt8 = 8) -> Data {
        var body: [UInt8] = []
        body.appendU16(5)
        body.append(addressSize)
        body.append(0)
        body.appendU32(UInt32(lists.count))

        var nextListOffset = UInt32(lists.count * 4)
        for list in lists {
            body.appendU32(nextListOffset)
            nextListOffset += UInt32(list.count)
        }
        for list in lists {
            body.append(contentsOf: list)
        }

        var result: [UInt8] = []
        result.appendU32(UInt32(body.count))
        result.append(contentsOf: body)
        return Data(result)
    }

    private static func absoluteListOffsets(_ lists: [[UInt8]]) -> [UInt32] {
        let offsetTableStart = UInt32(12)
        var nextListOffset = UInt32(lists.count * 4)
        var offsets: [UInt32] = []
        for list in lists {
            offsets.append(offsetTableStart + nextListOffset)
            nextListOffset += UInt32(list.count)
        }
        return offsets
    }

    private static func abbrev() -> [UInt8] {
        var abbrev: [UInt8] = []

        appendAbbrev(code: 0x01, tag: 0x11, hasChildren: true, attributes: [
            (0x74, 0x17),
            (0x73, 0x17)
        ], to: &abbrev)
        appendAbbrev(code: 0x02, tag: 0x0b, hasChildren: false, attributes: [
            (0x55, 0x23)
        ], to: &abbrev)
        appendAbbrev(code: 0x03, tag: 0x0b, hasChildren: false, attributes: [
            (0x55, 0x17)
        ], to: &abbrev)

        abbrev.append(0x00)
        return abbrev
    }

    private static func appendAbbrev(
        code: UInt64,
        tag: UInt64,
        hasChildren: Bool,
        attributes: [(UInt64, UInt64)],
        to abbrev: inout [UInt8]
    ) {
        abbrev.appendULEB128(code)
        abbrev.appendULEB128(tag)
        abbrev.append(hasChildren ? 0x01 : 0x00)
        for (attribute, form) in attributes {
            abbrev.appendULEB128(attribute)
            abbrev.appendULEB128(form)
        }
        abbrev.append(0x00)
        abbrev.append(0x00)
    }

    private static func assembleInfo(
        abbrev: [UInt8],
        die: [UInt8],
        debugAddr: Data,
        debugRnglists: Data,
        addressSize: UInt8 = 8
    ) -> DWARFReader.Sections {
        var body: [UInt8] = []
        body.appendU16(5)
        body.append(0x01)
        body.append(addressSize)
        body.appendU32(0)
        body.append(contentsOf: die)

        var info: [UInt8] = []
        info.appendU32(UInt32(body.count))
        info.append(contentsOf: body)

        return DWARFReader.Sections(
            debugInfo: Data(info),
            debugAbbrev: Data(abbrev),
            debugAddr: debugAddr,
            debugRnglists: debugRnglists
        )
    }

    private static func uleb(_ value: UInt64) -> [UInt8] {
        var bytes: [UInt8] = []
        bytes.appendULEB128(value)
        return bytes
    }

    private static func address(_ value: UInt64) -> [UInt8] {
        var bytes: [UInt8] = []
        bytes.appendU64(value)
        return bytes
    }

    private struct DIEBuilder {
        private(set) var bytes: [UInt8] = []

        mutating func append(_ byte: UInt8) {
            bytes.append(byte)
        }

        mutating func appendU32(_ value: UInt32) {
            bytes.appendU32(value)
        }

        mutating func appendULEB128(_ value: UInt64) {
            bytes.appendULEB128(value)
        }
    }
}

private extension Array where Element == UInt8 {
    mutating func appendU16(_ value: UInt16) {
        for i in 0..<2 {
            append(UInt8((value >> (8 * i)) & 0xff))
        }
    }

    mutating func appendU32(_ value: UInt32) {
        for i in 0..<4 {
            append(UInt8((value >> (8 * i)) & 0xff))
        }
    }

    mutating func appendU64(_ value: UInt64) {
        for i in 0..<8 {
            append(UInt8((value >> (8 * i)) & 0xff))
        }
    }

    mutating func appendULEB128(_ value: UInt64) {
        var value = value
        repeat {
            var byte = UInt8(value & 0x7f)
            value >>= 7
            if value != 0 {
                byte |= 0x80
            }
            append(byte)
        } while value != 0
    }
}

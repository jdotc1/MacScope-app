import Foundation
import XCTest
@testable import MacScope

final class DWARFLoclistTests: XCTestCase {
    func testPackage04FixtureRecoversNormalizedLoclists() throws {
        let loclists = try DWARFReader(sections: try Package04DWARFFixture.sections()).recoverLoclists()
        let rendered = Dictionary(uniqueKeysWithValues: loclists.map { ($0.name, Self.render($0.ranges)) })

        XCTAssertEqual(rendered, [
            "n": "0x0-0x30=reg0|0x30-0x6c=reg23|0x6c-0x70=<expr>|0x70-0x74=reg0|0x74-0x78=<expr>",
            "p": "0x0-0x20=reg1|0x20-0x64=reg19|0x64-0x70=<expr>|0x70-0x78=reg1",
            "acc": "0x0-0x30=<expr>|0x30-0x68=reg21|0x70-0x78=<expr>",
            "hi": "0x0-0x30=<expr>|0x30-0x68=reg22|0x70-0x78=<expr>",
            "i": "0x0-0x30=<expr>|0x30-0x58=reg20",
            "v": "0x40-0x58=reg8"
        ])

        let locals = try DWARFReader(sections: try Package04DWARFFixture.sections()).recoverLocals()
        XCTAssertEqual(locals.map { "\($0.function).\($0.name):\($0.location)" }, [
            "accumulate.n:",
            "accumulate.p:",
            "accumulate.acc:",
            "accumulate.hi:",
            "accumulate.i:",
            "accumulate.v:"
        ])
    }

    func testSyntheticLoclistsDecodeRangeFormsAndStopSafely() throws {
        let loclists = try DWARFReader(sections: SyntheticLoclistDWARF.sections()).recoverLoclists()
        let rendered = Dictionary(uniqueKeysWithValues: loclists.map { ($0.name, Self.render($0.ranges)) })

        XCTAssertEqual(
            rendered["rich"],
            "0x1-0x3=reg5|0x1010-0x1020=fbreg -4|0x1020-0x1028=breg3 2|" +
            "0x2000-0x2010=addr 0x1234|0x2010-0x2015=<expr>"
        )
        XCTAssertEqual(rendered["unknown"], "0x0-0x4=reg6")
        XCTAssertNil(rendered["truncated"])
    }

    private static func render(_ ranges: [DWARFLoclistRange]) -> String {
        ranges.map { range in
            "\(String(format: "0x%llx", range.lowPC))-\(String(format: "0x%llx", range.highPC))=\(range.location)"
        }.joined(separator: "|")
    }
}

private enum Package04DWARFFixture {
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
            debugLoclists: try load("debug_loclists")
        )
    }

    private static func sectionsDirectory() throws -> URL {
        var candidate = TestSourceRoot.fileURL(#filePath).deletingLastPathComponent()
        let fileManager = FileManager.default

        while candidate.path != "/" {
            let sections = candidate
                .appendingPathComponent("handoff_package", isDirectory: true)
                .appendingPathComponent("sections", isDirectory: true)
            if fileManager.fileExists(atPath: sections.appendingPathComponent("debug_loclists.bin").path) {
                return sections
            }
            candidate.deleteLastPathComponent()
        }

        throw XCTSkip("handoff_package/sections fixture is unavailable")
    }
}

private enum SyntheticLoclistDWARF {
    static func sections() -> DWARFReader.Sections {
        var builder = DIEBuilder()
        builder.mark("compile_unit")
        builder.append(0x01)
        builder.appendU32(0x0c)
        builder.appendU32(0x08)

        builder.mark("function")
        builder.append(0x02)
        builder.appendU64(0x1000)
        builder.appendCString("synthetic_loclists")

        appendLocal(name: "rich", loclistIndex: 0, to: &builder)
        appendLocal(name: "unknown", loclistIndex: 1, to: &builder)
        appendLocal(name: "truncated", loclistIndex: 2, to: &builder)
        builder.append(0x00)

        builder.mark("int")
        builder.append(0x04)
        builder.appendCString("int")
        builder.append(0x04)

        builder.append(0x00)

        return assembleInfo(
            abbrev: abbrev(),
            die: builder.resolvedDIE(),
            debugAddr: debugAddr(),
            debugLoclists: debugLoclists()
        )
    }

    private static func appendLocal(name: String, loclistIndex: UInt64, to builder: inout DIEBuilder) {
        builder.append(0x03)
        builder.appendULEB128(loclistIndex)
        builder.appendCString(name)
        builder.appendRef4(to: "int")
    }

    private static func debugAddr() -> Data {
        var bytes = [UInt8](repeating: 0, count: 8)
        bytes.appendU64(0x1000)
        bytes.appendU64(0x1010)
        bytes.appendU64(0x1020)
        return Data(bytes)
    }

    private static func debugLoclists() -> Data {
        let rich =
            [0x01] + uleb(0) +
            [0x04] + uleb(1) + uleb(3) + block([0x55]) +
            [0x02] + uleb(1) + uleb(2) + block([0x91] + sleb(-4)) +
            [0x03] + uleb(2) + uleb(8) + block([0x73, 0x02]) +
            [0x05] + block([0x57]) +
            [0x07] + address(0x2000) + address(0x2010) + block(exprAddr(0x1234)) +
            [0x08] + address(0x2010) + uleb(5) + block([0x11, 0x00, 0x9f]) +
            [0x00]

        let unknown =
            [0x04] + uleb(0) + uleb(4) + block([0x56]) +
            [0xff] +
            [0x04] + uleb(4) + uleb(8) + block([0x57]) +
            [0x00]

        let truncated = [0x04] + uleb(0) + uleb(4) + uleb(9) + [0x58]

        return makeLoclistsSection(lists: [rich, unknown, truncated])
    }

    private static func makeLoclistsSection(lists: [[UInt8]]) -> Data {
        var body: [UInt8] = []
        body.appendU16(5)
        body.append(8)
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

    private static func block(_ expression: [UInt8]) -> [UInt8] {
        uleb(UInt64(expression.count)) + expression
    }

    private static func exprAddr(_ value: UInt64) -> [UInt8] {
        [0x03] + address(value)
    }

    private static func address(_ value: UInt64) -> [UInt8] {
        var bytes: [UInt8] = []
        bytes.appendU64(value)
        return bytes
    }

    private static func uleb(_ value: UInt64) -> [UInt8] {
        var bytes: [UInt8] = []
        bytes.appendULEB128(value)
        return bytes
    }

    private static func sleb(_ value: Int64) -> [UInt8] {
        var bytes: [UInt8] = []
        bytes.appendSLEB128(value)
        return bytes
    }

    private static func abbrev() -> [UInt8] {
        var abbrev: [UInt8] = []

        appendAbbrev(code: 0x01, tag: 0x11, hasChildren: true, attributes: [
            (0x8c, 0x17),
            (0x73, 0x17)
        ], to: &abbrev)
        appendAbbrev(code: 0x02, tag: 0x2e, hasChildren: true, attributes: [
            (0x11, 0x01),
            (0x03, 0x08)
        ], to: &abbrev)
        appendAbbrev(code: 0x03, tag: 0x34, hasChildren: false, attributes: [
            (0x02, 0x22),
            (0x03, 0x08),
            (0x49, 0x13)
        ], to: &abbrev)
        appendAbbrev(code: 0x04, tag: 0x24, hasChildren: false, attributes: [
            (0x03, 0x08),
            (0x0b, 0x0b)
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
        debugLoclists: Data
    ) -> DWARFReader.Sections {
        var body: [UInt8] = []
        body.appendU16(5)
        body.append(0x01)
        body.append(0x08)
        body.appendU32(0)
        body.append(contentsOf: die)

        var info: [UInt8] = []
        info.appendU32(UInt32(body.count))
        info.append(contentsOf: body)
        return DWARFReader.Sections(
            debugInfo: Data(info),
            debugAbbrev: Data(abbrev),
            debugAddr: debugAddr,
            debugLoclists: debugLoclists
        )
    }

    private struct DIEBuilder {
        private static let cuHeaderSize = 12
        private var bytes: [UInt8] = []
        private var labels: [String: Int] = [:]
        private var refPatches: [(position: Int, target: String)] = []

        mutating func mark(_ label: String) {
            labels[label] = Self.cuHeaderSize + bytes.count
        }

        mutating func append(_ byte: UInt8) {
            bytes.append(byte)
        }

        mutating func appendCString(_ string: String) {
            bytes.append(contentsOf: string.utf8)
            bytes.append(0x00)
        }

        mutating func appendU32(_ value: UInt32) {
            bytes.appendU32(value)
        }

        mutating func appendU64(_ value: UInt64) {
            bytes.appendU64(value)
        }

        mutating func appendULEB128(_ value: UInt64) {
            bytes.appendULEB128(value)
        }

        mutating func appendRef4(to label: String) {
            refPatches.append((bytes.count, label))
            bytes.append(contentsOf: [0x00, 0x00, 0x00, 0x00])
        }

        func resolvedDIE() -> [UInt8] {
            var result = bytes
            for patch in refPatches {
                let offset = UInt32(labels[patch.target] ?? Int.max)
                for i in 0..<4 {
                    result[patch.position + i] = UInt8((offset >> (8 * i)) & 0xff)
                }
            }
            return result
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

    mutating func appendSLEB128(_ value: Int64) {
        var value = value
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
            append(byte)
        }
    }
}

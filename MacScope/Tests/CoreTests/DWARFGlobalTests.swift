import Foundation
import XCTest
@testable import MacScope

final class DWARFGlobalTests: XCTestCase {
    func testPackage03FixtureRecoversNamedFileScopeGlobals() throws {
        let globals = try DWARFReader(sections: try Package03DWARFFixture.sections()).recoverGlobals()

        XCTAssertEqual(globals, [
            DWARFGlobal(name: "g_counter", typeName: "long", address: 0x40),
            DWARFGlobal(name: "g_origin", typeName: "Point", address: 0x48),
            DWARFGlobal(name: "g_name", typeName: "const char *", address: 0x50),
            DWARFGlobal(name: "g_flags", typeName: "unsigned char", address: 0x6d4),
            DWARFGlobal(name: "g_scale", typeName: "double", address: 0x58),
            DWARFGlobal(name: "s_table", typeName: "int[4]", address: 0x60)
        ])
    }

    func testSyntheticGlobalsResolveInlineAndIndexedAddressesOnlyAtTopLevel() throws {
        let globals = try DWARFReader(sections: SyntheticGlobalDWARF.sections()).recoverGlobals()

        XCTAssertEqual(globals, [
            DWARFGlobal(name: "inline_counter", typeName: "long", address: 0x1122_3344_5566_7788),
            DWARFGlobal(name: "indexed_name", typeName: "const char *", address: 0x1020_3040_5060_7080),
            DWARFGlobal(name: "points", typeName: "Point[2]", address: 0x8877_6655_4433_2211)
        ])

        XCTAssertFalse(globals.contains { $0.name == "bad_index" })
        XCTAssertFalse(globals.contains { $0.name == "not_global" })
    }
}

private enum Package03DWARFFixture {
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
            debugLineStr: try load("debug_line_str")
        )
    }

    private static func sectionsDirectory() throws -> URL {
        var candidate = TestSourceRoot.fileURL(#filePath).deletingLastPathComponent()
        let fileManager = FileManager.default

        while candidate.path != "/" {
            let sections = candidate
                .appendingPathComponent("handoff_package", isDirectory: true)
                .appendingPathComponent("sections", isDirectory: true)
            if fileManager.fileExists(atPath: sections.appendingPathComponent("debug_info.bin").path) {
                return sections
            }
            candidate.deleteLastPathComponent()
        }

        throw XCTSkip("handoff_package/sections fixture is unavailable")
    }
}

private enum SyntheticGlobalDWARF {
    static func sections() -> DWARFReader.Sections {
        var builder = DIEBuilder()
        builder.mark("compile_unit")
        builder.append(0x01)

        appendGlobal(name: "inline_counter", expression: exprAddr(0x1122_3344_5566_7788), type: "long", to: &builder)
        appendGlobal(name: "indexed_name", expression: [0xa1, 0x00], type: "char_pointer", to: &builder)
        appendGlobal(name: "bad_index", expression: [0xa1, 0x7f], type: "long", to: &builder)
        appendGlobal(name: "points", expression: [0xa1, 0x01], type: "point_array", to: &builder)

        builder.mark("function")
        builder.append(0x0a)
        builder.appendU64(0x1000)
        builder.appendCString("has_child_variable")
        appendGlobal(name: "not_global", expression: exprAddr(0x9999), type: "long", to: &builder)
        builder.append(0x00)

        builder.mark("long")
        appendBaseType(code: 0x03, name: "long", byteSize: 8, to: &builder)

        builder.mark("char")
        appendBaseType(code: 0x03, name: "char", byteSize: 1, to: &builder)

        builder.mark("const_char")
        builder.append(0x05)
        builder.appendRef4(to: "char")

        builder.mark("char_pointer")
        builder.append(0x04)
        builder.appendRef4(to: "const_char")

        builder.mark("point")
        builder.append(0x06)
        builder.appendCString("Point")
        builder.append(0x08)
        appendMember(name: "x", type: "int", offset: 0, to: &builder)
        appendMember(name: "y", type: "int", offset: 4, to: &builder)
        builder.append(0x00)

        builder.mark("int")
        appendBaseType(code: 0x03, name: "int", byteSize: 4, to: &builder)

        builder.mark("point_array")
        builder.append(0x08)
        builder.appendRef4(to: "point")
        builder.append(0x09)
        builder.append(0x02)
        builder.append(0x00)

        builder.append(0x00)

        var debugAddr = [UInt8](repeating: 0, count: 8)
        debugAddr.appendU64(0x1020_3040_5060_7080)
        debugAddr.appendU64(0x8877_6655_4433_2211)

        return assembleInfo(
            abbrev: abbrev(),
            die: builder.resolvedDIE(),
            debugAddr: Data(debugAddr)
        )
    }

    private static func appendGlobal(
        name: String,
        expression: [UInt8],
        type: String,
        to builder: inout DIEBuilder
    ) {
        builder.append(0x02)
        builder.appendExprLoc(expression)
        builder.appendCString(name)
        builder.appendRef4(to: type)
    }

    private static func appendBaseType(code: UInt8, name: String, byteSize: UInt8, to builder: inout DIEBuilder) {
        builder.append(code)
        builder.appendCString(name)
        builder.append(byteSize)
    }

    private static func appendMember(name: String, type: String, offset: UInt8, to builder: inout DIEBuilder) {
        builder.append(0x07)
        builder.appendCString(name)
        builder.appendRef4(to: type)
        builder.append(offset)
    }

    private static func exprAddr(_ address: UInt64) -> [UInt8] {
        var bytes: [UInt8] = [0x03]
        bytes.appendU64(address)
        return bytes
    }

    private static func abbrev() -> [UInt8] {
        var abbrev: [UInt8] = []

        abbrev.append(0x01)
        abbrev.append(0x11)
        abbrev.append(0x01)
        abbrev.append(contentsOf: [0x00, 0x00])

        abbrev.append(0x02)
        abbrev.append(0x34)
        abbrev.append(0x00)
        abbrev.append(contentsOf: [0x02, 0x18])
        abbrev.append(contentsOf: [0x03, 0x08])
        abbrev.append(contentsOf: [0x49, 0x13])
        abbrev.append(contentsOf: [0x00, 0x00])

        abbrev.append(0x03)
        abbrev.append(0x24)
        abbrev.append(0x00)
        abbrev.append(contentsOf: [0x03, 0x08])
        abbrev.append(contentsOf: [0x0b, 0x0b])
        abbrev.append(contentsOf: [0x00, 0x00])

        abbrev.append(0x04)
        abbrev.append(0x0f)
        abbrev.append(0x00)
        abbrev.append(contentsOf: [0x49, 0x13])
        abbrev.append(contentsOf: [0x00, 0x00])

        abbrev.append(0x05)
        abbrev.append(0x26)
        abbrev.append(0x00)
        abbrev.append(contentsOf: [0x49, 0x13])
        abbrev.append(contentsOf: [0x00, 0x00])

        abbrev.append(0x06)
        abbrev.append(0x13)
        abbrev.append(0x01)
        abbrev.append(contentsOf: [0x03, 0x08])
        abbrev.append(contentsOf: [0x0b, 0x0b])
        abbrev.append(contentsOf: [0x00, 0x00])

        abbrev.append(0x07)
        abbrev.append(0x0d)
        abbrev.append(0x00)
        abbrev.append(contentsOf: [0x03, 0x08])
        abbrev.append(contentsOf: [0x49, 0x13])
        abbrev.append(contentsOf: [0x38, 0x0b])
        abbrev.append(contentsOf: [0x00, 0x00])

        abbrev.append(0x08)
        abbrev.append(0x01)
        abbrev.append(0x01)
        abbrev.append(contentsOf: [0x49, 0x13])
        abbrev.append(contentsOf: [0x00, 0x00])

        abbrev.append(0x09)
        abbrev.append(0x21)
        abbrev.append(0x00)
        abbrev.append(contentsOf: [0x37, 0x0b])
        abbrev.append(contentsOf: [0x00, 0x00])

        abbrev.append(0x0a)
        abbrev.append(0x2e)
        abbrev.append(0x01)
        abbrev.append(contentsOf: [0x11, 0x01])
        abbrev.append(contentsOf: [0x03, 0x08])
        abbrev.append(contentsOf: [0x00, 0x00])

        abbrev.append(0x00)
        return abbrev
    }

    private static func assembleInfo(abbrev: [UInt8], die: [UInt8], debugAddr: Data) -> DWARFReader.Sections {
        var body: [UInt8] = []
        body.append(contentsOf: [0x04, 0x00])
        body.append(contentsOf: [0x00, 0x00, 0x00, 0x00])
        body.append(0x08)
        body.append(contentsOf: die)

        var info: [UInt8] = []
        info.appendU32(UInt32(body.count))
        info.append(contentsOf: body)
        return DWARFReader.Sections(
            debugInfo: Data(info),
            debugAbbrev: Data(abbrev),
            debugAddr: debugAddr
        )
    }

    private struct DIEBuilder {
        private static let cuHeaderSize = 11
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

        mutating func appendU64(_ value: UInt64) {
            bytes.appendU64(value)
        }

        mutating func appendExprLoc(_ expression: [UInt8]) {
            bytes.appendULEB128(UInt64(expression.count))
            bytes.append(contentsOf: expression)
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

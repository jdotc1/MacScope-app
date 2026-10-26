import Foundation
import XCTest
@testable import MacScope

final class DWARFLocationTests: XCTestCase {
    func testPackage02FixtureRecoversNormalizedLocations() throws {
        let locals = try DWARFReader(sections: try Package02DWARFFixture.sections()).recoverLocals()
        let locations = Dictionary(uniqueKeysWithValues: locals.map { ("\($0.function).\($0.name)", $0.location) })

        XCTAssertEqual(locations["add.a"], "fbreg 12")
        XCTAssertEqual(locations["add.b"], "fbreg 8")
        XCTAssertEqual(locations["compute.node"], "fbreg -8")
        XCTAssertEqual(locations["compute.count"], "fbreg -12")
        XCTAssertEqual(locations["compute.op"], "breg31 24")
        XCTAssertEqual(locations["compute.total"], "breg31 16")
        XCTAssertEqual(locations["compute.local"], "breg31 8")
        XCTAssertEqual(locations["compute.flags"], "breg31 7")
        XCTAssertEqual(locations["compute.i"], "breg31 0")

        XCTAssertEqual(locals.map(LocalLocationProjection.init), [
            LocalLocationProjection(function: "add", name: "a", typeName: "int", role: "param"),
            LocalLocationProjection(function: "add", name: "b", typeName: "int", role: "param"),
            LocalLocationProjection(function: "compute", name: "node", typeName: "const Node *", role: "param"),
            LocalLocationProjection(function: "compute", name: "count", typeName: "unsigned int", role: "param"),
            LocalLocationProjection(function: "compute", name: "op", typeName: "BinOp", role: "param"),
            LocalLocationProjection(function: "compute", name: "total", typeName: "long", role: "local"),
            LocalLocationProjection(function: "compute", name: "local", typeName: "Point", role: "local"),
            LocalLocationProjection(function: "compute", name: "flags", typeName: "unsigned char", role: "local"),
            LocalLocationProjection(function: "compute", name: "i", typeName: "unsigned int", role: "local")
        ])
    }

    func testSyntheticLocationFormsAndMalformedExpressions() throws {
        let locals = try DWARFReader(sections: SyntheticLocationDWARF.sections()).recoverLocals()
        let byName = Dictionary(uniqueKeysWithValues: locals.map { ($0.name, $0) })

        XCTAssertEqual(byName["direct_addr"]?.location, "addr 0x1122334455667788")
        XCTAssertEqual(byName["indexed_addr"]?.location, "addr 0x1020304050607080")
        XCTAssertEqual(byName["reg_direct"]?.location, "reg5")
        XCTAssertEqual(byName["reg_indexed"]?.location, "reg33")
        XCTAssertEqual(byName["breg_indexed"]?.location, "breg34 -16")
        XCTAssertEqual(byName["cfa_plus_stack"]?.location, "cfa 32 stack_value")
        XCTAssertEqual(byName["reg_stack"]?.location, "reg6 stack_value")
        XCTAssertEqual(byName["unknown_opcode"]?.location, "")
        XCTAssertEqual(byName["truncated_addr"]?.location, "")
        XCTAssertEqual(byName["nonterminal_stack"]?.location, "")

        XCTAssertEqual(byName["direct_addr"]?.typeName, "int")
        XCTAssertEqual(byName["direct_addr"]?.role, "param")
        XCTAssertEqual(byName["indexed_addr"]?.role, "local")
    }
}

private struct LocalLocationProjection: Equatable {
    var function: String
    var name: String
    var typeName: String
    var role: String

    init(function: String, name: String, typeName: String, role: String) {
        self.function = function
        self.name = name
        self.typeName = typeName
        self.role = role
    }

    init(_ local: DWARFLocal) {
        self.init(
            function: local.function,
            name: local.name,
            typeName: local.typeName,
            role: local.role
        )
    }
}

private enum Package02DWARFFixture {
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

private enum SyntheticLocationDWARF {
    static func sections() -> DWARFReader.Sections {
        var builder = DIEBuilder()
        builder.mark("compile_unit")
        builder.append(0x01)

        builder.mark("function")
        builder.append(0x02)
        builder.appendU64(0x1000)
        builder.appendCString("synthetic_locations")

        appendParameter(name: "direct_addr", expression: exprAddr(0x1122_3344_5566_7788), to: &builder)
        appendVariable(name: "indexed_addr", expression: [0xa1, 0x00], to: &builder)
        appendVariable(name: "reg_direct", expression: [0x55], to: &builder)
        appendVariable(name: "reg_indexed", expression: [0x90, 0x21], to: &builder)
        appendVariable(name: "breg_indexed", expression: [0x92, 0x22] + sleb(-16), to: &builder)
        appendVariable(name: "cfa_plus_stack", expression: [0x9c, 0x23, 0x20, 0x9f], to: &builder)
        appendVariable(name: "reg_stack", expression: [0x56, 0x9f], to: &builder)
        appendVariable(name: "unknown_opcode", expression: [0xff], to: &builder)
        appendVariable(name: "truncated_addr", expression: [0x03, 0x01, 0x02], to: &builder)
        appendVariable(name: "nonterminal_stack", expression: [0x55, 0x9f, 0x9f], to: &builder)

        builder.append(0x00)

        builder.mark("int")
        builder.append(0x05)
        builder.appendCString("int")
        builder.append(0x04)

        builder.append(0x00)

        var debugAddr = [UInt8](repeating: 0, count: 8)
        debugAddr.appendU64(0x1020_3040_5060_7080)

        return assembleInfo(
            abbrev: abbrev(),
            die: builder.resolvedDIE(),
            debugAddr: Data(debugAddr)
        )
    }

    private static func appendParameter(name: String, expression: [UInt8], to builder: inout DIEBuilder) {
        appendLocal(code: 0x03, name: name, expression: expression, to: &builder)
    }

    private static func appendVariable(name: String, expression: [UInt8], to builder: inout DIEBuilder) {
        appendLocal(code: 0x04, name: name, expression: expression, to: &builder)
    }

    private static func appendLocal(code: UInt8, name: String, expression: [UInt8], to builder: inout DIEBuilder) {
        builder.append(code)
        builder.appendExprLoc(expression)
        builder.appendCString(name)
        builder.appendRef4(to: "int")
    }

    private static func exprAddr(_ address: UInt64) -> [UInt8] {
        var bytes: [UInt8] = [0x03]
        bytes.appendU64(address)
        return bytes
    }

    private static func sleb(_ value: Int64) -> [UInt8] {
        var bytes: [UInt8] = []
        bytes.appendSLEB128(value)
        return bytes
    }

    private static func abbrev() -> [UInt8] {
        var abbrev: [UInt8] = []

        abbrev.append(0x01)
        abbrev.append(0x11)
        abbrev.append(0x01)
        abbrev.append(contentsOf: [0x00, 0x00])

        abbrev.append(0x02)
        abbrev.append(0x2e)
        abbrev.append(0x01)
        abbrev.append(contentsOf: [0x11, 0x01])
        abbrev.append(contentsOf: [0x03, 0x08])
        abbrev.append(contentsOf: [0x00, 0x00])

        abbrev.append(0x03)
        abbrev.append(0x05)
        abbrev.append(0x00)
        abbrev.append(contentsOf: [0x02, 0x18])
        abbrev.append(contentsOf: [0x03, 0x08])
        abbrev.append(contentsOf: [0x49, 0x13])
        abbrev.append(contentsOf: [0x00, 0x00])

        abbrev.append(0x04)
        abbrev.append(0x34)
        abbrev.append(0x00)
        abbrev.append(contentsOf: [0x02, 0x18])
        abbrev.append(contentsOf: [0x03, 0x08])
        abbrev.append(contentsOf: [0x49, 0x13])
        abbrev.append(contentsOf: [0x00, 0x00])

        abbrev.append(0x05)
        abbrev.append(0x24)
        abbrev.append(0x00)
        abbrev.append(contentsOf: [0x03, 0x08])
        abbrev.append(contentsOf: [0x0b, 0x0b])
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

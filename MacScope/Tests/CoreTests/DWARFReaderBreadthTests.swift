import Foundation
import XCTest
@testable import MacScope

final class DWARFReaderBreadthTests: XCTestCase {
    func testPackage01FixtureRecoversTypeGraphAndTypedLocals() throws {
        let reader = DWARFReader(sections: try Package01DWARFFixture.sections())

        XCTAssertEqual(try reader.recoverFunctionSymbols(), [
            DWARFFunctionSymbol(address: 0x0, name: "add"),
            DWARFFunctionSymbol(address: 0x20, name: "compute")
        ])

        let types = try reader.recoverTypes()
        let byName = Dictionary(grouping: types, by: \.name)

        func assertType(_ name: String, kind: String, byteSize: Int? = nil) {
            let matches = byName[name] ?? []
            XCTAssertTrue(matches.contains { type in
                type.kind == kind && (byteSize == nil || type.byteSize == byteSize)
            }, "missing TYPE \(name) kind=\(kind) byteSize=\(String(describing: byteSize)); got \(matches)")
        }

        assertType("int", kind: "base", byteSize: 4)
        assertType("unsigned int", kind: "base", byteSize: 4)
        assertType("long", kind: "base", byteSize: 8)
        assertType("char", kind: "base", byteSize: 1)
        assertType("float", kind: "base", byteSize: 4)
        assertType("unsigned char", kind: "base", byteSize: 1)
        assertType("Node", kind: "struct", byteSize: 48)
        assertType("Point", kind: "typedef", byteSize: 8)
        assertType("Point", kind: "struct", byteSize: 8)
        assertType("Color", kind: "enum", byteSize: 4)
        assertType("Value", kind: "union", byteSize: 8)
        assertType("BinOp", kind: "typedef", byteSize: 8)
        assertType("char[16]", kind: "array", byteSize: 16)
        assertType("const Node *", kind: "pointer", byteSize: 8)
        assertType("void *", kind: "pointer", byteSize: 8)
        assertType("int (*)(int, int)", kind: "pointer", byteSize: 8)

        let node = try XCTUnwrap(types.first { $0.name == "Node" && $0.kind == "struct" })
        XCTAssertEqual(node.members, [
            DWARFTypeMember(name: "next", typeName: "Node *", byteOffset: 0),
            DWARFTypeMember(name: "origin", typeName: "const Point *", byteOffset: 8),
            DWARFTypeMember(name: "label", typeName: "char[16]", byteOffset: 16),
            DWARFTypeMember(name: "color", typeName: "Color", byteOffset: 32),
            DWARFTypeMember(name: "val", typeName: "Value", byteOffset: 40)
        ])

        let color = try XCTUnwrap(types.first { $0.name == "Color" && $0.kind == "enum" })
        XCTAssertEqual(color.enumerators, [
            DWARFEnumerator(name: "RED", value: 0),
            DWARFEnumerator(name: "GREEN", value: 1),
            DWARFEnumerator(name: "BLUE", value: 2)
        ])

        XCTAssertEqual(try reader.recoverLocals().map(LocalProjection.init), [
            LocalProjection(function: "add", name: "a", typeName: "int", role: "param"),
            LocalProjection(function: "add", name: "b", typeName: "int", role: "param"),
            LocalProjection(function: "compute", name: "node", typeName: "const Node *", role: "param"),
            LocalProjection(function: "compute", name: "count", typeName: "unsigned int", role: "param"),
            LocalProjection(function: "compute", name: "op", typeName: "BinOp", role: "param"),
            LocalProjection(function: "compute", name: "total", typeName: "long", role: "local"),
            LocalProjection(function: "compute", name: "local", typeName: "Point", role: "local"),
            LocalProjection(function: "compute", name: "flags", typeName: "unsigned char", role: "local"),
            LocalProjection(function: "compute", name: "i", typeName: "unsigned int", role: "local")
        ])
    }
}

private struct LocalProjection: Equatable {
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

private enum Package01DWARFFixture {
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

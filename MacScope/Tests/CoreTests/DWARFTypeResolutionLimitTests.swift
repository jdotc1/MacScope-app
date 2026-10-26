import Foundation
import XCTest
@testable import MacScope

final class DWARFTypeResolutionLimitTests: XCTestCase {
    func testPointerReferenceDepthBoundaryPreservesValidSpelling() throws {
        let sections = TypeLimitFixture.chain(count: 3, typedefs: false)
        let types = try reader(sections, depth: 4).recoverTypes()
        XCTAssertEqual(types.last, DWARFType(name: "int * * *", kind: "pointer", byteSize: 8))
        assertLimit("type reference depth limit exceeded") {
            _ = try reader(sections, depth: 3).recoverTypes()
        }
    }

    func testTypedefSizeReferenceDepthBoundaryPreservesValidSize() throws {
        let sections = TypeLimitFixture.chain(count: 3, typedefs: true)
        let types = try reader(sections, depth: 4).recoverTypes()
        XCTAssertEqual(types.last, DWARFType(name: "Alias2", kind: "typedef", byteSize: 4))
        assertLimit("type reference depth limit exceeded") {
            _ = try reader(sections, depth: 3).recoverTypes()
        }
    }

    func testRenderedUTF8NameBoundaryIncludesPointerSuffix() throws {
        let sections = TypeLimitFixture.chain(count: 1, typedefs: false, baseName: "é")
        XCTAssertEqual(try reader(sections, bytes: 4).recoverTypes().last?.name, "é *")
        assertLimit("rendered type name byte limit exceeded") {
            _ = try reader(sections, bytes: 3).recoverTypes()
        }
    }

    func testDirectNameCannotExceedRenderedByteLimit() throws {
        let sections = TypeLimitFixture.chain(count: 0, typedefs: false, baseName: "long")
        XCTAssertEqual(try reader(sections, bytes: 4).recoverTypes().first?.name, "long")
        assertLimit("rendered type name byte limit exceeded") {
            _ = try reader(sections, bytes: 3).recoverTypes()
        }
    }

    func testFunctionPointerParametersShareOneRenderedNameLimit() throws {
        let sections = TypeLimitFixture.functionPointer()
        let expected = "int (*)(int, int)"
        XCTAssertEqual(try reader(sections, bytes: expected.utf8.count).recoverTypes().last?.name, expected)
        assertLimit("rendered type name byte limit exceeded") {
            _ = try reader(sections, bytes: expected.utf8.count - 1).recoverTypes()
        }
    }

    func testFunctionPointerCountsSubroutineInReferenceDepth() throws {
        let sections = TypeLimitFixture.functionPointer()
        XCTAssertEqual(try reader(sections, depth: 3).recoverTypes().last?.name, "int (*)(int, int)")
        assertLimit("type reference depth limit exceeded") {
            _ = try reader(sections, depth: 2).recoverTypes()
        }
    }

    func testArrayDimensionsPreserveNameAndSizeWithinLimit() throws {
        let sections = TypeLimitFixture.array()
        XCTAssertEqual(try reader(sections, bytes: 9).recoverTypes().last,
                       DWARFType(name: "int[2][3]", kind: "array", byteSize: 24))
        assertLimit("rendered type name byte limit exceeded") {
            _ = try reader(sections, bytes: 8).recoverTypes()
        }
    }

    func testQualifierPrefixCountsTowardRenderedNameLimit() throws {
        let sections = TypeLimitFixture.qualified()
        XCTAssertEqual(try reader(sections, bytes: 9).recoverTypes().last,
                       DWARFType(name: "const int", kind: "const", byteSize: 4))
        assertLimit("rendered type name byte limit exceeded") {
            _ = try reader(sections, bytes: 8).recoverTypes()
        }
    }

    func testAnonymousCompositeQualificationCountsTowardNameLimit() throws {
        let sections = TypeLimitFixture.anonymousComposite()
        let expected = "Outer::structure "
        XCTAssertEqual(try reader(sections, bytes: expected.utf8.count).recoverTypes().last?.name, expected)
        assertLimit("rendered type name byte limit exceeded") {
            _ = try reader(sections, bytes: expected.utf8.count - 1).recoverTypes()
        }
    }

    private func reader(
        _ sections: DWARFReader.Sections,
        depth: Int = 16,
        bytes: Int = 256
    ) -> DWARFReader {
        DWARFReader(sections: sections, typeResolutionLimits: .init(
            maximumReferenceDepth: depth,
            maximumRenderedNameBytes: bytes
        ))
    }

    private func assertLimit(
        _ reason: String,
        file: StaticString = #filePath,
        line: UInt = #line,
        operation: () throws -> Void
    ) {
        XCTAssertThrowsError(try operation(), file: file, line: line) { error in
            XCTAssertEqual(error as? DWARFReaderError, .malformed(reason), file: file, line: line)
        }
    }
}

private struct TypeLimitFixture {
    private var dies: [UInt8] = [1]

    static func chain(count: Int, typedefs: Bool, baseName: String = "int") -> DWARFReader.Sections {
        var fixture = TypeLimitFixture()
        var previous = fixture.base(name: baseName)
        for index in 0..<count {
            let offset = fixture.offset
            fixture.dies.append(typedefs ? 4 : 3)
            if typedefs { fixture.string("Alias\(index)") }
            fixture.u32(previous)
            previous = offset
        }
        return fixture.sections()
    }

    static func functionPointer() -> DWARFReader.Sections {
        var fixture = TypeLimitFixture()
        let base = fixture.base(name: "int")
        let function = fixture.offset
        fixture.dies.append(5)
        fixture.u32(base)
        for _ in 0..<2 {
            fixture.dies.append(6)
            fixture.u32(base)
        }
        fixture.dies.append(0)
        fixture.dies.append(3)
        fixture.u32(function)
        return fixture.sections()
    }

    static func array() -> DWARFReader.Sections {
        var fixture = TypeLimitFixture()
        let base = fixture.base(name: "int")
        fixture.dies.append(7)
        fixture.u32(base)
        fixture.dies += [8, 2, 8, 3, 0]
        return fixture.sections()
    }

    static func qualified() -> DWARFReader.Sections {
        var fixture = TypeLimitFixture()
        let base = fixture.base(name: "int")
        fixture.dies.append(11)
        fixture.u32(base)
        return fixture.sections()
    }

    static func anonymousComposite() -> DWARFReader.Sections {
        var fixture = TypeLimitFixture()
        fixture.dies.append(9)
        fixture.string("Outer")
        fixture.dies += [10, 0]
        return fixture.sections()
    }

    private var offset: UInt32 { UInt32(11 + dies.count) }

    private mutating func base(name: String) -> UInt32 {
        let offset = self.offset
        dies.append(2)
        string(name)
        dies.append(4)
        return offset
    }

    private mutating func string(_ value: String) {
        dies += Array(value.utf8) + [0]
    }

    private mutating func u32(_ value: UInt32) {
        dies += Self.littleEndian(value)
    }

    private func sections() -> DWARFReader.Sections {
        // DWARF 4, one compilation unit, 8-byte addresses, CU-relative ref4s.
        let body: [UInt8] = [4, 0, 0, 0, 0, 0, 8] + dies + [0]
        let abbrev: [UInt8] = [
            1, 0x11, 1, 0, 0,
            2, 0x24, 0, 0x03, 0x08, 0x0b, 0x0b, 0, 0,
            3, 0x0f, 0, 0x49, 0x13, 0, 0,
            4, 0x16, 0, 0x03, 0x08, 0x49, 0x13, 0, 0,
            5, 0x15, 1, 0x49, 0x13, 0, 0,
            6, 0x05, 0, 0x49, 0x13, 0, 0,
            7, 0x01, 1, 0x49, 0x13, 0, 0,
            8, 0x21, 0, 0x37, 0x0b, 0, 0,
            9, 0x13, 1, 0x03, 0x08, 0, 0,
            10, 0x13, 0, 0, 0,
            11, 0x26, 0, 0x49, 0x13, 0, 0,
            0
        ]
        return .init(debugInfo: Data(Self.littleEndian(UInt32(body.count)) + body),
                     debugAbbrev: Data(abbrev))
    }

    private static func littleEndian(_ value: UInt32) -> [UInt8] {
        (0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
    }
}

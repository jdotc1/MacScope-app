import XCTest
@testable import MacScope

final class CTypeHeaderBitfieldTests: XCTestCase {
    private func parse(_ source: String) -> CTypeHeaderParser.Result {
        CTypeHeaderParser.parse(source, idProvider: { UUID(uuidString: "00000000-0000-0000-0000-000000000000")! })
    }

    private func catalog(from result: CTypeHeaderParser.Result) -> [String: TypeDefinition] {
        Dictionary(uniqueKeysWithValues: result.types.map { ($0.name, $0) })
    }

    private func offsets(for type: TypeDefinition, in catalog: [String: TypeDefinition]) -> [String: Int] {
        Dictionary(uniqueKeysWithValues: type.memberLayout(in: catalog).compactMap { item in
            item.field.name.isEmpty ? nil : (item.field.name, item.offset)
        })
    }

    func testParsesNamedAndUnnamedBitWidths() {
        let result = parse("""
        struct Packed { unsigned a:3; unsigned b:5; unsigned c:1; };
        struct Padded { unsigned a:3; unsigned :5; unsigned b:4; };
        struct ZeroReset { unsigned a:3; unsigned :0; unsigned b:3; };
        """)

        XCTAssertTrue(result.diagnostics.isEmpty, "\(result.diagnostics)")
        let types = catalog(from: result)
        XCTAssertEqual(types["Packed"]?.fields.map(\.bitWidth), [3, 5, 1])
        XCTAssertEqual(types["Packed"]?.fields.map(\.name), ["a", "b", "c"])
        XCTAssertEqual(types["Padded"]?.fields.map(\.bitWidth), [3, 5, 4])
        XCTAssertEqual(types["Padded"]?.fields.map(\.name), ["a", "", "b"])
        XCTAssertEqual(types["ZeroReset"]?.fields.map(\.bitWidth), [3, 0, 3])
        XCTAssertEqual(types["ZeroReset"]?.fields.map(\.name), ["a", "", "b"])
    }

    func testBitFieldStructSizesMatchArm64Targets() throws {
        let result = parse("""
        struct Packed { unsigned a:3; unsigned b:5; unsigned c:1; };
        struct Overflow { unsigned a:20; unsigned b:20; };
        struct ZeroReset { unsigned a:3; unsigned :0; unsigned b:3; };
        struct ThenNormal { unsigned a:4; int x; };
        struct Interleaved { unsigned a:5; short mid; unsigned b:5; int end; };
        """)

        XCTAssertTrue(result.diagnostics.isEmpty, "\(result.diagnostics)")
        let types = catalog(from: result)
        XCTAssertEqual(TypeDefinition.size(ofType: "Packed", in: types), 4)
        XCTAssertEqual(TypeDefinition.size(ofType: "Overflow", in: types), 8)
        XCTAssertEqual(TypeDefinition.size(ofType: "ZeroReset", in: types), 8)
        XCTAssertEqual(TypeDefinition.size(ofType: "ThenNormal", in: types), 8)
        XCTAssertEqual(TypeDefinition.size(ofType: "Interleaved", in: types), 12)

        let thenNormal = try XCTUnwrap(types["ThenNormal"])
        XCTAssertEqual(offsets(for: thenNormal, in: types)["x"], 4)

        let interleaved = try XCTUnwrap(types["Interleaved"])
        let interleavedOffsets = offsets(for: interleaved, in: types)
        XCTAssertEqual(interleavedOffsets["mid"], 2)
        XCTAssertEqual(interleavedOffsets["end"], 8)
    }

    func testBitFieldOnlyUnionUsesLargestContainer() throws {
        let result = parse("union BitUnion { unsigned a:1; unsigned short b:12; _Bool flag:1; };")

        XCTAssertTrue(result.diagnostics.isEmpty, "\(result.diagnostics)")
        let types = catalog(from: result)
        let union = try XCTUnwrap(types["BitUnion"])
        XCTAssertEqual(union.kind, .union)
        XCTAssertEqual(union.fields.map(\.bitWidth), [1, 12, 1])
        XCTAssertEqual(union.memberLayout(in: types).map(\.offset), [0, 0, 0])
        XCTAssertEqual(TypeDefinition.size(ofType: "BitUnion", in: types), 4)
    }

    func testInvalidBitFieldsSkipWithDiagnostic() {
        let result = parse("""
        struct Bad {
            int x:40;
            double nope:1;
            _Bool flag:2;
            int ok;
        };
        """)

        let bad = result.types.first
        XCTAssertEqual(bad?.fields.map(\.name), ["ok"])
        XCTAssertEqual(TypeDefinition.size(ofType: "Bad", in: catalog(from: result)), 4)
        XCTAssertEqual(result.diagnostics.count, 3)
        XCTAssertTrue(result.diagnostics.contains { $0.contains("width 40") })
        XCTAssertTrue(result.diagnostics.contains { $0.contains("non-integer type") })
        XCTAssertTrue(result.diagnostics.contains { $0.contains("_Bool") && $0.contains("1-bit") })
    }
}

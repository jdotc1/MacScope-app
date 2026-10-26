import XCTest
@testable import MacScope

final class CTypeHeaderAnonAggregateTests: XCTestCase {
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

    func testAnonymousStructPromotesMembersAndConsumesBlockSize() throws {
        let result = parse("struct S1 { int a; struct { int x; int y; }; int b; };")
        XCTAssertTrue(result.diagnostics.isEmpty, "\(result.diagnostics)")

        let types = catalog(from: result)
        let s1 = try XCTUnwrap(types["S1"])
        let layout = s1.memberLayout(in: types)
        XCTAssertEqual(layout.map(\.field.name), ["a", "x", "y", "b"])
        XCTAssertEqual(offsets(for: s1, in: types), ["a": 0, "x": 4, "y": 8, "b": 12])
        XCTAssertEqual(TypeDefinition.size(ofType: "S1", in: types), 16)
    }

    func testAnonymousUnionPromotesMembersAtSharedOffset() throws {
        let result = parse("""
        struct S2 { int tag; union { int i; float f; char c[4]; }; };
        struct S3 { int kind; union { struct { int a; int b; } pair; long big; }; };
        """)
        XCTAssertTrue(result.diagnostics.isEmpty, "\(result.diagnostics)")

        let types = catalog(from: result)
        let s2 = try XCTUnwrap(types["S2"])
        XCTAssertEqual(s2.memberLayout(in: types).map(\.field.name), ["tag", "i", "f", "c"])
        XCTAssertEqual(offsets(for: s2, in: types), ["tag": 0, "i": 4, "f": 4, "c": 4])
        XCTAssertEqual(TypeDefinition.size(ofType: "S2", in: types), 8)

        let s3 = try XCTUnwrap(types["S3"])
        XCTAssertEqual(s3.memberLayout(in: types).map(\.field.name), ["kind", "pair", "big"])
        XCTAssertEqual(offsets(for: s3, in: types), ["kind": 0, "pair": 8, "big": 8])
        XCTAssertEqual(TypeDefinition.size(ofType: "S3", in: types), 16)
    }

    func testNestedAnonymousAggregatesPromoteRecursively() throws {
        let result = parse("struct S4 { int a; struct { int b; union { int c; short d; }; }; };")
        XCTAssertTrue(result.diagnostics.isEmpty, "\(result.diagnostics)")

        let types = catalog(from: result)
        let s4 = try XCTUnwrap(types["S4"])
        XCTAssertEqual(s4.memberLayout(in: types).map(\.field.name), ["a", "b", "c", "d"])
        XCTAssertEqual(offsets(for: s4, in: types), ["a": 0, "b": 4, "c": 8, "d": 8])
        XCTAssertEqual(TypeDefinition.size(ofType: "S4", in: types), 12)
    }

    func testNamedInlineStructMemberIsNotPromoted() throws {
        let result = parse("struct S8 { int a; struct Inner { int p; int q; } nested; int b; };")
        XCTAssertTrue(result.diagnostics.isEmpty, "\(result.diagnostics)")

        let types = catalog(from: result)
        let s8 = try XCTUnwrap(types["S8"])
        XCTAssertEqual(s8.memberLayout(in: types).map(\.field.name), ["a", "nested", "b"])
        XCTAssertEqual(offsets(for: s8, in: types), ["a": 0, "nested": 4, "b": 12])
        XCTAssertNil(offsets(for: s8, in: types)["p"])
        XCTAssertNil(offsets(for: s8, in: types)["q"])
        XCTAssertEqual(TypeDefinition.size(ofType: "S8", in: types), 16)
    }

    func testTaggedUnnamedInlineStructSkipsWithDiagnostic() throws {
        let result = parse("struct TaggedSkip { int before; struct Local { int hidden; }; int after; };")
        XCTAssertTrue(result.diagnostics.contains { $0.contains("tagged unnamed struct") }, "\(result.diagnostics)")

        let types = catalog(from: result)
        let taggedSkip = try XCTUnwrap(types["TaggedSkip"])
        XCTAssertEqual(taggedSkip.memberLayout(in: types).map(\.field.name), ["before", "after"])
        XCTAssertEqual(offsets(for: taggedSkip, in: types), ["before": 0, "after": 4])
        XCTAssertEqual(TypeDefinition.size(ofType: "TaggedSkip", in: types), 8)
    }
}

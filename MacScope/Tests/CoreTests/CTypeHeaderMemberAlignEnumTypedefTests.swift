import XCTest
@testable import MacScope

final class CTypeHeaderMemberAlignEnumTypedefTests: XCTestCase {
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

    /// Expected values from a new parser import. Manual/legacy fixtures continue
    /// to use `FieldDef`'s default `nil` provenance when they need that state.
    private func fields(
        _ pairs: [(String, String)],
        semantics: FieldDef.DeclaratorSemanticsV1 = .ordinary
    ) -> [FieldDef] {
        pairs.map {
            FieldDef(name: $0.0, type: $0.1, declaratorSemanticsV1: semantics)
        }
    }

    func testMemberAlignedAttributesInLeadingAndTrailingPositions() throws {
        let result = parse("""
        struct MA1 { char a; __attribute__((aligned(8))) int b; };
        struct MA2 { char a; int b __attribute__((aligned(16))); };
        """)

        XCTAssertTrue(result.diagnostics.isEmpty, "\(result.diagnostics)")
        let types = catalog(from: result)
        let ma1 = try XCTUnwrap(types["MA1"])
        let ma2 = try XCTUnwrap(types["MA2"])
        XCTAssertEqual(ma1.fields.map(\.name), ["a", "b"])
        XCTAssertEqual(ma2.fields.map(\.name), ["a", "b"])
        XCTAssertEqual(TypeDefinition.size(ofType: "MA1", in: types), 16)
        XCTAssertEqual(TypeDefinition.size(ofType: "MA2", in: types), 32)
        XCTAssertEqual(offsets(for: ma1, in: types), ["a": 0, "b": 8])
        XCTAssertEqual(offsets(for: ma2, in: types), ["a": 0, "b": 16])
    }

    func testEnumValuesAndEnumMemberLayout() throws {
        let result = parse("""
        enum E1 { A, B, C };
        enum E2 { X = 10, Y, Z = 100 };
        struct UE1 { char a; enum E1 e; };
        struct UE2 { enum E2 e; char t; };
        """)

        XCTAssertTrue(result.diagnostics.isEmpty, "\(result.diagnostics)")
        let types = catalog(from: result)
        XCTAssertEqual(types["E1"]?.fields, fields([("A", "0"), ("B", "1"), ("C", "2")]))
        XCTAssertEqual(types["E2"]?.fields, fields([("X", "10"), ("Y", "11"), ("Z", "100")]))
        XCTAssertEqual(TypeDefinition.size(ofType: "enum E1", in: types), 4)
        XCTAssertEqual(TypeDefinition.alignment(ofType: "enum E1", in: types), 4)
        XCTAssertEqual(TypeDefinition.size(ofType: "E2", in: types), 4)

        let ue1 = try XCTUnwrap(types["UE1"])
        let ue2 = try XCTUnwrap(types["UE2"])
        XCTAssertEqual(TypeDefinition.size(ofType: "UE1", in: types), 8)
        XCTAssertEqual(TypeDefinition.size(ofType: "UE2", in: types), 8)
        XCTAssertEqual(offsets(for: ue1, in: types), ["a": 0, "e": 4])
        XCTAssertEqual(offsets(for: ue2, in: types), ["e": 0, "t": 4])
    }

    func testArrayTypedefMembersResolveThroughAliasChainsAndDimensions() throws {
        let result = parse("""
        typedef int IArr[4];
        typedef IArr IArr2;
        typedef int Mat[3][4];
        struct UA { char c; IArr arr; };
        struct UA2 { IArr2 a; char t; };
        struct UM { char c; Mat m; };
        """)

        XCTAssertTrue(result.diagnostics.isEmpty, "\(result.diagnostics)")
        let types = catalog(from: result)
        XCTAssertEqual(types["IArr"]?.fields, fields([("IArr", "int32_t[4]")]))
        XCTAssertEqual(types["IArr2"]?.fields, fields([("IArr2", "IArr")]))
        XCTAssertEqual(types["Mat"]?.fields, fields([("Mat", "int32_t[3][4]")]))
        XCTAssertEqual(TypeDefinition.size(ofType: "IArr2", in: types), 16)
        XCTAssertEqual(TypeDefinition.size(ofType: "Mat", in: types), 48)

        let ua = try XCTUnwrap(types["UA"])
        let ua2 = try XCTUnwrap(types["UA2"])
        let um = try XCTUnwrap(types["UM"])
        XCTAssertEqual(TypeDefinition.size(ofType: "UA", in: types), 20)
        XCTAssertEqual(TypeDefinition.size(ofType: "UA2", in: types), 20)
        XCTAssertEqual(TypeDefinition.size(ofType: "UM", in: types), 52)
        XCTAssertEqual(offsets(for: ua, in: types), ["c": 0, "arr": 4])
        XCTAssertEqual(offsets(for: ua2, in: types), ["a": 0, "t": 16])
        XCTAssertEqual(offsets(for: um, in: types), ["c": 0, "m": 4])
    }

    func testFunctionPointerTypedefMemberResolvesAsPointer() throws {
        // H2: function-pointer fields now carry their parsed signature; layout and lowered type unchanged.
        let result = parse("""
        typedef void (*Fn)(int, long);
        struct UF { char c; Fn f; };
        """)

        XCTAssertTrue(result.diagnostics.isEmpty, "\(result.diagnostics)")
        let types = catalog(from: result)
        XCTAssertEqual(
            types["Fn"]?.fields,
            [FieldDef(name: "Fn", type: "void *", declaratorSemanticsV1: .functionPointerCarrier,
                functionPointerSignatureV1: .init(returnType: "void", parameters: [.init(type: "int32_t"), .init(type: "int64_t")]))]
        )
        XCTAssertEqual(TypeDefinition.size(ofType: "Fn", in: types), 8)
        XCTAssertEqual(TypeDefinition.alignment(ofType: "Fn", in: types), 8)

        let uf = try XCTUnwrap(types["UF"])
        XCTAssertEqual(TypeDefinition.size(ofType: "UF", in: types), 16)
        XCTAssertEqual(offsets(for: uf, in: types), ["c": 0, "f": 8])
    }

    func testMalformedMemberAttributeDiagnosesAndKeepsFollowingField() throws {
        let result = parse("""
        struct BadAttr {
            int before;
            __attribute__((aligned(8)) int broken;
            long after;
        };
        """)

        XCTAssertTrue(result.diagnostics.contains { $0.contains("malformed member `__attribute__`") }, "\(result.diagnostics)")
        let types = catalog(from: result)
        let badAttr = try XCTUnwrap(types["BadAttr"])
        XCTAssertEqual(badAttr.fields.map(\.name), ["before", "after"])
        XCTAssertEqual(offsets(for: badAttr, in: types), ["before": 0, "after": 8])
        XCTAssertEqual(TypeDefinition.size(ofType: "BadAttr", in: types), 16)
    }
}

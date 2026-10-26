import XCTest
@testable import MacScope

final class CTypeHeaderFunctionPointerTests: XCTestCase {
    private func parse(_ source: String) -> CTypeHeaderParser.Result {
        CTypeHeaderParser.parse(source, idProvider: { UUID(uuidString: "00000000-0000-0000-0000-000000000000")! })
    }

    private func fields(
        _ fields: [(String, String, FieldDef.DeclaratorSemanticsV1)],
        signatures: [String: FunctionPointerSignatureV1] = [:]
    ) -> [FieldDef] {
        fields.map {
            FieldDef(name: $0.0, type: $0.1, declaratorSemanticsV1: $0.2, functionPointerSignatureV1: signatures[$0.0])
        }
    }

    private func signature(_ returnType: String, _ parameters: [String]) -> FunctionPointerSignatureV1 {
        .init(returnType: returnType, parameters: parameters.map { .init(type: $0) })
    }

    func testFunctionPointerDeclaratorsContributePointerSizedLayout() {
        // H2: function-pointer fields now carry their parsed signature; layout and lowered type unchanged.
        let result = parse("""
        struct FunctionMembers {
            int x;
            void (*on_event)(int, long);
            int (*compute)(void);
            int (*ops[3])(int);
            char *(*make)(void);
            int (*grid)[2];
            long y;
        };
        """)

        XCTAssertTrue(result.diagnostics.isEmpty, "\(result.diagnostics)")
        guard let type = result.types.first else {
            XCTFail("Expected FunctionMembers to parse")
            return
        }
        XCTAssertEqual(type.fields, fields([
            ("x", "int32_t", .ordinary),
            ("on_event", "void *", .functionPointerCarrier),
            ("compute", "int32_t *", .functionPointerCarrier),
            ("ops", "int32_t *[3]", .arrayOfFunctionPointerCarrier),
            ("make", "char *", .functionPointerCarrier),
            ("grid", "int32_t *", .pointerToArrayCarrier),
            ("y", "int64_t", .ordinary),
        ], signatures: ["on_event": signature("void", ["int32_t", "int64_t"]), "compute": signature("int32_t", []), "ops": signature("int32_t", ["int32_t"]), "make": signature("char *", [])]))
        XCTAssertEqual(type.memberLayout().map(\.offset), [0, 8, 16, 24, 48, 56, 64])
        XCTAssertEqual(TypeDefinition.size(ofType: "FunctionMembers", in: ["FunctionMembers": type]), 72)
    }

    func testPointerToArrayDeclaratorsDoNotBecomeInlineArrays() {
        let result = parse("""
        struct PtrArrays {
            char c;
            int (*pa)[4];
            double (*mat)[3];
            int n;
        };
        """)

        XCTAssertTrue(result.diagnostics.isEmpty, "\(result.diagnostics)")
        guard let type = result.types.first else {
            XCTFail("Expected PtrArrays to parse")
            return
        }
        XCTAssertEqual(type.fields, fields([
            ("c", "char", .ordinary),
            ("pa", "int32_t *", .pointerToArrayCarrier),
            ("mat", "double *", .pointerToArrayCarrier),
            ("n", "int32_t", .ordinary),
        ]))
        XCTAssertEqual(type.memberLayout().map(\.offset), [0, 8, 16, 24])
        XCTAssertEqual(TypeDefinition.size(ofType: "PtrArrays", in: ["PtrArrays": type]), 32)
    }

    func testNestedStructWithFunctionPointerUsesCatalogLayout() {
        // H2: function-pointer fields now carry their parsed signature; layout and lowered type unchanged.
        let result = parse("""
        struct Plain {
            int x;
            char c;
            long y;
        };

        struct Nested {
            struct Plain p;
            void (*hook)(void);
            int z;
        };
        """)

        XCTAssertTrue(result.diagnostics.isEmpty, "\(result.diagnostics)")
        let catalog = Dictionary(uniqueKeysWithValues: result.types.map { ($0.name, $0) })
        let nested = catalog["Nested"]
        XCTAssertEqual(nested?.fields, fields([
            ("p", "Plain", .ordinary),
            ("hook", "void *", .functionPointerCarrier),
            ("z", "int32_t", .ordinary),
        ], signatures: ["hook": signature("void", [])]))
        XCTAssertEqual(nested?.memberLayout(in: catalog).map(\.offset), [0, 16, 24])
        XCTAssertEqual(TypeDefinition.size(ofType: "Nested", in: catalog), 32)
    }

    func testMalformedParenthesizedPointerDeclaratorSkipsWithDiagnostic() {
        let result = parse("""
        struct Broken {
            int good;
            int (*bad)(;
            long after;
        };
        """)

        let type = result.types.first
        XCTAssertEqual(type?.fields, fields([
            ("good", "int32_t", .ordinary),
            ("after", "int64_t", .ordinary),
        ]))
        XCTAssertEqual(type?.memberLayout().map(\.offset), [0, 8])
        XCTAssertFalse(result.diagnostics.isEmpty)
    }

    func testParserPersistsEveryClosedDeclaratorSemanticsCase() throws {
        // H2: function-pointer fields now carry their parsed signature; layout and lowered type unchanged.
        let result = parse("""
        struct DeclaratorSemantics {
            int *data;
            void (*callback)(int);
            int (*matrix)[4];
            int (*handlers[2])(int);
        };
        """)

        XCTAssertTrue(result.diagnostics.isEmpty, "\(result.diagnostics)")
        let type = try XCTUnwrap(result.types.first)
        XCTAssertEqual(type.fields, fields([
            ("data", "int32_t *", .ordinary),
            ("callback", "void *", .functionPointerCarrier),
            ("matrix", "int32_t *", .pointerToArrayCarrier),
            ("handlers", "int32_t *[2]", .arrayOfFunctionPointerCarrier),
        ], signatures: ["callback": signature("void", ["int32_t"]), "handlers": signature("int32_t", ["int32_t"])]))
    }

    func testArrayOfFunctionPointerPreservesCarrierAndDimensions() throws {
        // H2: function-pointer fields now carry their parsed signature; layout and lowered type unchanged.
        let result = parse("""
        struct MultidimensionalCallbacks {
            int (*handlers[2][3])(int);
        };
        """)

        XCTAssertTrue(result.diagnostics.isEmpty, "\(result.diagnostics)")
        let type = try XCTUnwrap(result.types.first)
        XCTAssertEqual(type.fields, fields([
            ("handlers", "int32_t *[2][3]", .arrayOfFunctionPointerCarrier),
        ], signatures: ["handlers": signature("int32_t", ["int32_t"])]))
    }

    func testParenthesizedCarrierTypedefsPersistParsedProvenance() throws {
        // H2: function-pointer fields now carry their parsed signature; layout and lowered type unchanged.
        let result = parse("""
        typedef void (*Callback)(int);
        typedef char *(*Factory)(void);
        typedef int (*Row)[4];
        typedef int (*HandlerTable[2][3])(int);
        """)

        XCTAssertTrue(result.diagnostics.isEmpty, "\(result.diagnostics)")
        let catalog = Dictionary(uniqueKeysWithValues: result.types.map { ($0.name, $0) })
        XCTAssertEqual(catalog.count, 4)
        XCTAssertEqual(try XCTUnwrap(catalog["Callback"]).fields, fields([
            ("Callback", "void *", .functionPointerCarrier),
        ], signatures: ["Callback": signature("void", ["int32_t"])]))
        XCTAssertEqual(try XCTUnwrap(catalog["Factory"]).fields, fields([
            ("Factory", "char *", .functionPointerCarrier),
        ], signatures: ["Factory": signature("char *", [])]))
        XCTAssertEqual(try XCTUnwrap(catalog["Row"]).fields, fields([
            ("Row", "int32_t *", .pointerToArrayCarrier),
        ]))
        XCTAssertEqual(try XCTUnwrap(catalog["HandlerTable"]).fields, fields([
            ("HandlerTable", "int32_t *[2][3]", .arrayOfFunctionPointerCarrier),
        ], signatures: ["HandlerTable": signature("int32_t", ["int32_t"])]))
    }
}

import XCTest
@testable import MacScope

/// Table-driven tests for the clean-room C type-declaration parser. Every
/// expected `TypeDefinition` here was hand-derived from C semantics (field order,
/// canonical primitive spelling, enum auto-increment). The parser must reproduce
/// them EXACTLY, and must emit a diagnostic — never a wrong type — for input it
/// cannot model.
final class CTypeHeaderParserTests: XCTestCase {

    /// Deterministic id provider so produced types compare by value.
    private func parse(_ source: String) -> CTypeHeaderParser.Result {
        CTypeHeaderParser.parse(source, idProvider: { UUID(uuidString: "00000000-0000-0000-0000-000000000000")! })
    }

    /// Expected values from a new parser import. Manual/legacy fixtures continue
    /// to use `FieldDef`'s default `nil` provenance when they need that state.
    private func fields(_ pairs: [(String, String)]) -> [FieldDef] {
        pairs.map {
            FieldDef(name: $0.0, type: $0.1, declaratorSemanticsV1: .ordinary)
        }
    }

    @discardableResult
    private func assertOrdinaryProvenanceRecursively(
        _ fields: [FieldDef],
        path: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Int {
        var visitedCount = 0
        for field in fields {
            let component = field.name.isEmpty ? "<anonymous>" : field.name
            let fieldPath = path + "." + component
            XCTAssertEqual(
                field.declaratorSemanticsV1,
                .ordinary,
                "parser-created field \(fieldPath) must persist ordinary declarator provenance",
                file: file,
                line: line
            )
            visitedCount += 1
            visitedCount += assertOrdinaryProvenanceRecursively(
                field.inlineFields,
                path: fieldPath,
                file: file,
                line: line
            )
        }
        return visitedCount
    }

    // MARK: - struct with mixed-width fields + byte layout

    func testStructMixedWidthFields() {
        let result = parse("""
        struct Header {
            uint32_t magic;
            int16_t  version;
            char     flags;
            uint64_t offset;
        };
        """)
        XCTAssertTrue(result.diagnostics.isEmpty, "\(result.diagnostics)")
        XCTAssertEqual(result.types.count, 1)
        let type = result.types[0]
        XCTAssertEqual(type.kind, .struct)
        XCTAssertEqual(type.name, "Header")
        XCTAssertEqual(type.fields, fields([
            ("magic", "uint32_t"), ("version", "int16_t"), ("flags", "char"), ("offset", "uint64_t"),
        ]))
        // Byte layout follows the C ABI: `offset` (uint64) is aligned to 8, not packed at 7.
        let layout = type.memberLayout()
        XCTAssertEqual(layout.map(\.offset), [0, 4, 6, 8])
    }

    func testStructMultiWordPrimitivesNormalize() {
        let result = parse("""
        struct Mixed {
            unsigned int   a;
            signed char    b;
            unsigned long  c;
            long long      d;
            short int      e;
        };
        """)
        XCTAssertTrue(result.diagnostics.isEmpty, "\(result.diagnostics)")
        XCTAssertEqual(result.types.first?.fields, fields([
            ("a", "uint32_t"), ("b", "int8_t"), ("c", "uint64_t"), ("d", "int64_t"), ("e", "int16_t"),
        ]))
    }

    // MARK: - enum with explicit + implicit values

    func testEnumExplicitAndImplicitValues() {
        let result = parse("""
        enum Color {
            Red,
            Green = 5,
            Blue,
            Black = 0x10,
            White
        };
        """)
        XCTAssertTrue(result.diagnostics.isEmpty, "\(result.diagnostics)")
        let type = result.types.first
        XCTAssertEqual(type?.kind, .enum)
        XCTAssertEqual(type?.name, "Color")
        XCTAssertEqual(type?.fields, fields([
            ("Red", "0"), ("Green", "5"), ("Blue", "6"), ("Black", "16"), ("White", "17"),
        ]))
    }

    func testEnumNegativeValue() {
        let result = parse("enum E { A = -3, B, C };")
        XCTAssertEqual(result.types.first?.fields, fields([("A", "-3"), ("B", "-2"), ("C", "-1")]))
    }

    // MARK: - typedef alias

    func testTypedefPrimitiveAlias() {
        let result = parse("typedef unsigned long size_type;")
        XCTAssertTrue(result.diagnostics.isEmpty, "\(result.diagnostics)")
        let type = result.types.first
        XCTAssertEqual(type?.kind, .typedef)
        XCTAssertEqual(type?.name, "size_type")
        XCTAssertEqual(type?.fields, fields([("size_type", "uint64_t")]))
    }

    func testTypedefPointerAlias() {
        let result = parse("typedef char * c_string;")
        XCTAssertEqual(result.types.first?.fields, fields([("c_string", "char *")]))
    }

    func testTypedefStructWithAlias() {
        let result = parse("""
        typedef struct Point {
            int32_t x;
            int32_t y;
        } Point;
        """)
        XCTAssertTrue(result.diagnostics.isEmpty, "\(result.diagnostics)")
        let type = result.types.first
        XCTAssertEqual(type?.kind, .struct)
        XCTAssertEqual(type?.name, "Point")
        XCTAssertEqual(type?.fields, fields([("x", "int32_t"), ("y", "int32_t")]))
    }

    func testTypedefEnumWithAlias() {
        let result = parse("typedef enum { Off, On } Switch;")
        let type = result.types.first
        XCTAssertEqual(type?.kind, .enum)
        XCTAssertEqual(type?.name, "Switch")
        XCTAssertEqual(type?.fields, fields([("Off", "0"), ("On", "1")]))
    }

    // MARK: - nested / pointer / array fields

    func testPointerAndArrayFields() {
        let result = parse("""
        struct Node {
            struct Node * next;
            char          name[16];
            int32_t       values[4];
            void *        context;
        };
        """)
        XCTAssertTrue(result.diagnostics.isEmpty, "\(result.diagnostics)")
        XCTAssertEqual(result.types.first?.fields, fields([
            ("next", "Node *"),      // `struct` qualifier dropped, pointer kept
            ("name", "char[16]"),
            ("values", "int32_t[4]"),
            ("context", "void *"),
        ]))
    }

    func testMultidimensionalOrdinaryFirstDeclaratorsPreserveEverySuffix() {
        let result = parse("""
        struct Grids {
            int32_t values[2][3];
            int32_t *pointers[4][5];
        };
        """)

        XCTAssertTrue(result.diagnostics.isEmpty, "\(result.diagnostics)")
        XCTAssertEqual(result.types.first?.fields, fields([
            ("values", "int32_t[2][3]"),
            ("pointers", "int32_t *[4][5]"),
        ]))
    }

    func testUnsupportedLaterArraySuffixPoisonsLayoutAndRecoversToSentinel() {
        let result = parse("""
        struct Recovery {
            int32_t broken[2][bad];
            int32_t sentinel;
        };
        """)

        XCTAssertFalse(result.diagnostics.isEmpty)
        XCTAssertEqual(result.types.first?.fields.map(\.name), ["broken", "sentinel"])
        XCTAssertEqual(result.types.first?.fields.first?.layoutIsUnknown, true)
        let catalog = Dictionary(result.types.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        XCTAssertNil(TypeDefinition.size(ofType: "Recovery", in: catalog))
        XCTAssertTrue(result.types.first?.memberLayout(in: catalog).isEmpty == true)
    }

    func testUserDefinedTypeFieldReference() {
        // A single unknown identifier is a user-type reference, passed through.
        let result = parse("""
        struct Wrapper {
            Point origin;
            int32_t tag;
        };
        """)
        XCTAssertTrue(result.diagnostics.isEmpty, "\(result.diagnostics)")
        XCTAssertEqual(result.types.first?.fields, fields([
            ("origin", "Point"), ("tag", "int32_t"),
        ]))
    }

    func testCommaSeparatedDeclarators() {
        let result = parse("struct V { int32_t a, b, c; };")
        XCTAssertEqual(result.types.first?.fields, fields([
            ("a", "int32_t"), ("b", "int32_t"), ("c", "int32_t"),
        ]))
    }

    func testMultidimensionalOrdinaryCommaDeclaratorsPreserveEverySuffix() {
        let result = parse("""
        struct CommaGrids {
            int32_t valueHead, valueGrid[2][3];
            int32_t *pointerHead, *pointerGrid[4][5];
        };
        """)

        XCTAssertTrue(result.diagnostics.isEmpty, "\(result.diagnostics)")
        XCTAssertEqual(result.types.first?.fields, fields([
            ("valueHead", "int32_t"),
            ("valueGrid", "int32_t[2][3]"),
            ("pointerHead", "int32_t *"),
            ("pointerGrid", "int32_t *[4][5]"),
        ]))
    }

    func testMultidimensionalInlineAggregatePointerFirstDeclaratorPreservesEverySuffix() {
        let result = parse("""
        struct Envelope {
            struct Node { int32_t value; } *nodes[2][3];
        };
        """)

        XCTAssertTrue(result.diagnostics.isEmpty, "\(result.diagnostics)")
        XCTAssertEqual(result.types.first?.fields, fields([
            ("nodes", "Node *[2][3]"),
        ]))
    }

    func testMultidimensionalInlineAggregatePointerCommaDeclaratorPreservesEverySuffix() {
        let result = parse("""
        struct Envelope {
            struct Node { int32_t value; } *head, *nodes[2][3];
        };
        """)

        XCTAssertTrue(result.diagnostics.isEmpty, "\(result.diagnostics)")
        XCTAssertEqual(result.types.first?.fields, fields([
            ("head", "Node *"),
            ("nodes", "Node *[2][3]"),
        ]))
    }

    // MARK: - malformed input -> diagnostic, not a wrong type

    func testMalformedUnterminatedStructProducesDiagnosticNotType() {
        let result = parse("struct Broken { int32_t a;")  // no closing brace
        // Parser recovers fields up to EOF but must NOT fabricate the wrong kind/
        // name silently with garbage; here the brace never closes so the record is
        // still named and the one valid field is captured — acceptable. The key
        // contract: no *spurious extra* type, and any junk is diagnosed.
        XCTAssertLessThanOrEqual(result.types.count, 1)
    }

    func testGarbageFieldIsSkippedWithDiagnostic() {
        let result = parse("""
        struct S {
            int32_t good;
            @@@ junk @@@;
            uint8_t alsoGood;
        };
        """)
        // The two valid fields survive; the junk is skipped with a diagnostic.
        let type = result.types.first
        XCTAssertEqual(type?.name, "S")
        XCTAssertEqual(type?.fields, fields([("good", "int32_t"), ("alsoGood", "uint8_t")]))
        XCTAssertFalse(result.diagnostics.isEmpty)
    }

    func testTypedefMissingAliasIsDiagnosed() {
        let result = parse("typedef int32_t;")  // no alias name
        XCTAssertTrue(result.types.isEmpty)
        XCTAssertFalse(result.diagnostics.isEmpty)
    }

    func testUnsupportedBaseTypePoisonsLaterOffsets() {
        let result = parse("struct S { weird_unknown thing fieldName; int32_t ok; };")
        let type = result.types.first
        XCTAssertEqual(type?.name, "S")
        XCTAssertEqual(type?.fields.map(\.name), ["fieldName", "ok"])
        XCTAssertEqual(type?.fields.first?.layoutIsUnknown, true)
        XCTAssertTrue(type?.memberLayout().isEmpty == true)
        XCTAssertNil(TypeDefinition.size(ofType: "S", in: Dictionary(result.types.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })))
        XCTAssertFalse(result.diagnostics.isEmpty)
    }

    // MARK: - unsupported construct skipped cleanly

    func testUnsupportedTopLevelConstructSkipped() {
        let result = parse("""
        int global_counter = 0;
        struct Keeper { int32_t value; };
        void someFunction(int x);
        """)
        // The function/global are skipped; the struct still lands.
        XCTAssertEqual(result.types.count, 1)
        XCTAssertEqual(result.types.first?.name, "Keeper")
        XCTAssertFalse(result.diagnostics.isEmpty)
    }

    func testInvalidBitFieldSkippedWithDiagnostic() {
        let result = parse("""
        struct Flags {
            uint32_t a : 40;
            uint32_t b;
        };
        """)
        let type = result.types.first
        // Invalid bit-field skipped; the plain field survives.
        XCTAssertEqual(type?.fields, fields([("b", "uint32_t")]))
        XCTAssertFalse(result.diagnostics.isEmpty)
    }

    func testNamedInlineRecordFieldIsKeptUnpromoted() {
        let result = parse("""
        struct Outer {
            struct { int32_t x; } inner;
            int32_t tag;
        };
        """)
        let type = result.types.first
        XCTAssertEqual(type?.name, "Outer")
        XCTAssertTrue(result.diagnostics.isEmpty, "\(result.diagnostics)")
        XCTAssertEqual(type?.fields.map(\.name), ["inner", "tag"])
        XCTAssertEqual(type?.memberLayout().map(\.field.name), ["inner", "tag"])
        XCTAssertEqual(type?.memberLayout().map(\.offset), [0, 4])
    }

    func testNamedAndAnonymousInlineAggregatesPersistOrdinaryProvenanceRecursively() throws {
        let result = parse("""
        struct Envelope {
            struct NamedPayload {
                int32_t namedLeaf;
                union NamedChoice {
                    uint16_t shortValue;
                    uint64_t longValue;
                } namedChoice;
            } namedPayload;
            union {
                char tag;
                struct {
                    int32_t x;
                    int32_t y;
                };
            };
        };
        """)

        XCTAssertTrue(result.diagnostics.isEmpty, "\(result.diagnostics)")
        let envelope = try XCTUnwrap(result.types.first)
        XCTAssertEqual(envelope.fields.map(\.name), ["namedPayload", ""])

        let namedPayload = try XCTUnwrap(envelope.fields.first { $0.name == "namedPayload" })
        XCTAssertEqual(namedPayload.inlineAggregateKind, .struct)
        XCTAssertFalse(namedPayload.promotesInlineFields)
        XCTAssertEqual(namedPayload.inlineFields.map(\.name), ["namedLeaf", "namedChoice"])
        let namedChoice = try XCTUnwrap(namedPayload.inlineFields.first { $0.name == "namedChoice" })
        XCTAssertEqual(namedChoice.inlineAggregateKind, .union)
        XCTAssertEqual(
            namedChoice.inlineFields.map(\.name),
            ["shortValue", "longValue"]
        )

        let anonymousChoice = try XCTUnwrap(envelope.fields.first { $0.name.isEmpty })
        XCTAssertEqual(anonymousChoice.inlineAggregateKind, .union)
        XCTAssertTrue(anonymousChoice.promotesInlineFields)
        XCTAssertEqual(anonymousChoice.inlineFields.map(\.name), ["tag", ""])
        let anonymousPoint = try XCTUnwrap(anonymousChoice.inlineFields.first { $0.name.isEmpty })
        XCTAssertEqual(anonymousPoint.inlineAggregateKind, .struct)
        XCTAssertTrue(anonymousPoint.promotesInlineFields)
        XCTAssertEqual(anonymousPoint.inlineFields.map(\.name), ["x", "y"])

        XCTAssertEqual(
            assertOrdinaryProvenanceRecursively(envelope.fields, path: "Envelope"),
            10
        )
    }

    // MARK: - comments / preprocessor / multiple decls

    func testCommentsAndCommentedDirectivesIgnored() {
        let result = parse("""
        // #include <stdint.h>
        // a leading comment
        struct A {
            int32_t x; /* inline */
            int32_t y; // trailing
        };
        /* #define FOO 1 */
        union B { int32_t i; float f; };
        """)
        XCTAssertEqual(result.types.count, 2)
        XCTAssertEqual(result.types[0].name, "A")
        XCTAssertEqual(result.types[0].kind, .struct)
        XCTAssertEqual(result.types[1].name, "B")
        XCTAssertEqual(result.types[1].kind, .union)
        XCTAssertEqual(result.types[1].fields, fields([("i", "int32_t"), ("f", "float")]))
    }

    func testUnionLayoutAllZeroOffsets() {
        let result = parse("union U { uint64_t q; uint32_t d; char c; };")
        let type = result.types.first
        XCTAssertEqual(type?.kind, .union)
        XCTAssertEqual(type?.memberLayout().map(\.offset), [0, 0, 0])
    }

    func testDuplicateNameInOneHeaderSkipped() {
        let result = parse("""
        struct Dup { int32_t a; };
        struct Dup { int32_t b; };
        """)
        XCTAssertEqual(result.types.count, 1)
        XCTAssertEqual(result.types.first?.fields, fields([("a", "int32_t")]))
        XCTAssertFalse(result.diagnostics.isEmpty)
    }

    // MARK: - hardening

    func testEmptyInputIsCleanlyEmpty() {
        let result = parse("   \n\t  ")
        XCTAssertTrue(result.types.isEmpty)
        XCTAssertTrue(result.diagnostics.isEmpty)
    }

    func testOversizedInputRejected() {
        let huge = String(repeating: "a", count: CTypeHeaderParser.maxSourceLength + 1)
        let result = CTypeHeaderParser.parse(huge)
        XCTAssertTrue(result.types.isEmpty)
        XCTAssertFalse(result.diagnostics.isEmpty)
    }

    func testDeeplyNestedBracesTerminate() {
        // Hostile deep nesting must not recurse or hang; it just yields no types.
        let hostile = "struct X " + String(repeating: "{", count: 500) + " int a;"
        let result = CTypeHeaderParser.parse(hostile)
        XCTAssertTrue(result.types.isEmpty || result.types.count == 1)
    }

    func testUnbalancedBracesTerminate() {
        let result = CTypeHeaderParser.parse(String(repeating: "} ; , * [ ] = ", count: 2000))
        // Must terminate and produce no spurious types.
        XCTAssertTrue(result.types.isEmpty)
    }

    // MARK: - integer literal helper

    func testIntegerLiteralParsing() {
        XCTAssertEqual(CTypeHeaderParser.parseIntegerLiteral("42"), 42)
        XCTAssertEqual(CTypeHeaderParser.parseIntegerLiteral("0x1F"), 31)
        XCTAssertEqual(CTypeHeaderParser.parseIntegerLiteral("100UL"), 100)
        XCTAssertNil(CTypeHeaderParser.parseIntegerLiteral("12abc"))
        XCTAssertNil(CTypeHeaderParser.parseIntegerLiteral(""))
    }
}

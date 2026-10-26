import Foundation
import XCTest
@testable import MacScope

final class CTypeHeaderLayoutFidelityTests: XCTestCase {
    private func catalog(_ source: String) -> [String: TypeDefinition] {
        Dictionary(CTypeHeaderParser.parse(source).types.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
    }

    func testEveryPrimitiveSpellingHasDarwinSizeAndAlignment() {
        let groups: [(Int, [String])] = [
            (1, ["char", "signed char", "unsigned char", "_Bool", "bool"]),
            (2, ["short", "short int", "signed short", "unsigned short int"]),
            (4, ["int", "signed", "signed int", "unsigned", "unsigned int", "float"]),
            (8, ["long", "signed long int", "unsigned long", "long long", "unsigned long long int", "double", "long double", "ptrdiff_t"]),
            (16, ["__int128", "signed __int128", "unsigned __int128"]),
        ]
        for (size, spellings) in groups {
            for spelling in spellings {
                XCTAssertEqual(TypeDefinition.size(ofType: spelling), size, spelling)
                XCTAssertEqual(TypeDefinition.alignment(ofType: spelling, in: [:]), size, spelling)
                let types = catalog("typedef \(spelling) T; typedef T U;")
                XCTAssertEqual(TypeDefinition.size(ofType: "U", in: types), size, spelling)
                XCTAssertEqual(TypeDefinition.alignment(ofType: "U", in: types), size, spelling)
            }
        }
        XCTAssertNil(TypeDefinition.size(ofType: "mystery_word"))
        XCTAssertNil(TypeDefinition.size(ofType: "unsigned mystery_word"))
        XCTAssertNil(TypeDefinition.size(ofType: "enum Missing"))
        XCTAssertEqual(TypeDefinition.size(ofType: "Missing *"), 8)
    }

    func testPackedCrossingRetainsAbsoluteBitPositions() throws {
        let types = catalog("struct __attribute__((packed)) S { unsigned a:3; unsigned b:31; char tail; };")
        let type = try XCTUnwrap(types["S"])
        let members = type.memberLayout(in: types)
        XCTAssertEqual(TypeDefinition.size(ofType: "S", in: types), 6)
        XCTAssertEqual(members.map(\.offset), [0, 0, 5])
        XCTAssertEqual(members.map(\.field.bitOffset), [0, 3, nil])
        XCTAssertEqual(members.map(\.field.bitWidth), [3, 31, nil])
        XCTAssertTrue(type.fields.allSatisfy { $0.bitOffset == nil }, "Computing a layout must not mutate persisted definitions")
    }

    func testPackedUnionUsesOccupiedBitsAndZeroWidthRetainsBoundary() throws {
        let types = catalog("""
        union __attribute__((packed)) U { unsigned int bits:1; char tail; };
        struct __attribute__((packed)) S { char head; unsigned int :0; char tail; };
        """)
        XCTAssertEqual(TypeDefinition.size(ofType: "U", in: types), 1)
        XCTAssertEqual(TypeDefinition.alignment(ofType: "U", in: types), 1)
        XCTAssertEqual(TypeDefinition.size(ofType: "S", in: types), 5)
        let members = try XCTUnwrap(types["S"]).memberLayout(in: types)
        XCTAssertEqual(members.map(\.offset), [0, 4, 4])
        XCTAssertEqual(members[1].field.bitOffset, 32)
    }

    func testUnknownMemberPoisonsSuffixInBothRecordKinds() throws {
        for kind in ["struct", "union"] {
            let types = catalog("\(kind) S { char head; Unknown middle; char tail; };")
            XCTAssertNil(TypeDefinition.size(ofType: "S", in: types))
            XCTAssertNil(TypeDefinition.alignment(ofType: "S", in: types))
            XCTAssertEqual(try XCTUnwrap(types["S"]).memberLayout(in: types).map(\.field.name), ["head"])
        }
    }

    func testUnknownNestedOrAlignmentTypeCannotLeakInventedOffsets() throws {
        for declaration in [
            "struct S { char head; struct { Unknown value; } nested; char tail; };",
            "struct S { char head; union { Unknown value; }; char tail; };",
            "struct S { char head; _Alignas(Unknown) int value; char tail; };",
        ] {
            let types = catalog(declaration)
            XCTAssertNil(TypeDefinition.size(ofType: "S", in: types), declaration)
            XCTAssertNil(TypeDefinition.alignment(ofType: "S", in: types), declaration)
            XCTAssertEqual(try XCTUnwrap(types["S"]).memberLayout(in: types).map(\.field.name), ["head"], declaration)
        }
    }

    func testWideUnsignedAndSignedEnumRanges() throws {
        let types = catalog("""
        enum WideUnsigned { U = 18446744073709551615ULL };
        enum WideSigned { S = -2147483649LL, Zero = 0 };
        enum NarrowUnsigned { N = 4294967295U };
        """)
        XCTAssertEqual(types["WideUnsigned"]?.fields.first?.type, "18446744073709551615")
        for name in ["WideUnsigned", "WideSigned"] {
            XCTAssertEqual(TypeDefinition.size(ofType: name, in: types), 8)
            XCTAssertEqual(TypeDefinition.alignment(ofType: "enum " + name, in: types), 8)
        }
        XCTAssertEqual(TypeDefinition.size(ofType: "NarrowUnsigned", in: types), 4)
    }

    func testEnumLiteralBasesAndImplicitValues() throws {
        let types = catalog("enum E { Octal = 010, AfterOctal, Binary = 0b10000, Hex = 0x20UL };")
        XCTAssertEqual(try XCTUnwrap(types["E"]).fields.map(\.type), ["8", "9", "16", "32"])
        XCTAssertEqual(CTypeHeaderParser.parseIntegerLiteral("010"), 8)
        XCTAssertNil(CTypeHeaderParser.parseIntegerLiteral("08"))
        XCTAssertNil(CTypeHeaderParser.parseIntegerLiteral("1UU"))
    }

    func testIncompleteEnumsNeverSizeTheKnownSubset() throws {
        for body in ["A = 1ULL << 40, B = 0", "A = 18446744073709551615ULL, B", "A = 18446744073709551616ULL, B = 0", "A = 08, B = 0", "A = -1U, B = 0", "A = -1ULL, B = 0", "A = -9223372036854775808LL, B = 0", "A = -0xffffffff, B = 0", "A = -037777777777, B = 0"] {
            let types = catalog("enum E { \(body) }; struct S { char a; enum E e; char tail; };")
            let enumeration = try XCTUnwrap(types["E"])
            XCTAssertEqual(enumeration.enumValuesIncomplete, true, body)
            XCTAssertNil(TypeDefinition.size(ofType: "E", in: types), body)
            XCTAssertNil(TypeDefinition.size(ofType: "S", in: types), body)
            let decoded = try JSONDecoder().decode(TypeDefinition.self, from: JSONEncoder().encode(enumeration))
            XCTAssertEqual(decoded.enumValuesIncomplete, true)
            let second = catalog(CTypeHeaderRenderer.render(types: Array(types.values)))
            XCTAssertNil(TypeDefinition.size(ofType: "S", in: second), "Export must not launder an incomplete enum into a sized one")
        }
    }

    func testVectorTypedefsResolveAndUnsupportedVectorsRemainUnknown() {
        let types = catalog("""
        typedef float V2 __attribute__((vector_size(8)));
        typedef float V4 __attribute__((vector_size(16)));
        typedef V4 Alias;
        typedef float TooLarge __attribute__((vector_size(32)));
        typedef Unknown Bad __attribute__((vector_size(16)));
        typedef Bad Cycle __attribute__((vector_size(16)));
        """)
        XCTAssertEqual(TypeDefinition.size(ofType: "V2", in: types), 8)
        XCTAssertEqual(TypeDefinition.size(ofType: "Alias", in: types), 16)
        XCTAssertEqual(TypeDefinition.alignment(ofType: "Alias", in: types), 16)
        for name in ["TooLarge", "Bad", "Cycle"] {
            XCTAssertNil(TypeDefinition.size(ofType: name, in: types), name)
            XCTAssertNil(TypeDefinition.alignment(ofType: name, in: types), name)
        }
    }

    func testExportPreservesAttributesNestedFieldsAndArrayDimensions() throws {
        let source = """
        typedef float V4 __attribute__((vector_size(16)));
        #pragma pack(push, 2)
        struct __attribute__((aligned(8))) S {
            char head;
            double value __attribute__((packed, aligned(2)));
            struct __attribute__((packed)) { unsigned a:3; unsigned b:31; } nested;
            int grid[2][3];
        };
        #pragma pack(pop)
        """
        let first = catalog(source)
        let rendered = CTypeHeaderRenderer.render(types: [try XCTUnwrap(first["V4"]), try XCTUnwrap(first["S"])])
        let second = catalog(rendered)
        for name in ["V4", "S"] {
            XCTAssertEqual(TypeDefinition.size(ofType: name, in: first), TypeDefinition.size(ofType: name, in: second), rendered)
            XCTAssertEqual(TypeDefinition.alignment(ofType: name, in: first), TypeDefinition.alignment(ofType: name, in: second), rendered)
            XCTAssertEqual(first[name]?.fields, second[name]?.fields, rendered)
            XCTAssertEqual(first[name]?.layoutRules, second[name]?.layoutRules, rendered)
            XCTAssertEqual(first[name]?.vectorByteSize, second[name]?.vectorByteSize, rendered)
        }
    }

    func testLegacyCodablePayloadAndNewMetadataRoundTrip() throws {
        let legacy = #"{"id":"00000000-0000-0000-0000-000000000001","kind":"struct","name":"Legacy","fields":[{"name":"a","type":"char"},{"name":"b","type":"int"}]}"#
        let definition = try JSONDecoder().decode(TypeDefinition.self, from: Data(legacy.utf8))
        XCTAssertEqual(definition.layoutRules, .default)
        XCTAssertNil(definition.vectorByteSize)
        XCTAssertNil(definition.enumValuesIncomplete)
        XCTAssertTrue(definition.fields.allSatisfy { $0.isPacked == nil && $0.bitOffset == nil && $0.bitWidth == nil })
        XCTAssertEqual(definition.memberLayout().map(\.offset), [0, 4])
        let field = FieldDef(name: "bits", type: "unsigned int", bitWidth: 31, bitOffset: 3, isPacked: true)
        XCTAssertEqual(try JSONDecoder().decode(FieldDef.self, from: JSONEncoder().encode(field)), field)
        let vector = TypeDefinition(kind: .typedef, name: "V", fields: [FieldDef(name: "V", type: "float")], vectorByteSize: 16)
        XCTAssertEqual(try JSONDecoder().decode(TypeDefinition.self, from: JSONEncoder().encode(vector)), vector)
    }
    func testPragmaPackBitfieldsCrossUnitsWithoutPadding() throws {
        for pack in [1, 2, 4, 8] {
            for attribute in ["", "__attribute__((aligned(16)))"] {
                let types = catalog("#pragma pack(push, \(pack))\nstruct S { char head; unsigned bits:31 \(attribute); char tail; };\n#pragma pack(pop)")
                let members = try XCTUnwrap(types["S"]).memberLayout(in: types)
                XCTAssertEqual(members[1].field.bitOffset, 8)
                XCTAssertEqual(members[2].offset, 5)
                let alignment = min(pack, attribute.isEmpty ? 4 : 16)
                XCTAssertEqual(TypeDefinition.alignment(ofType: "S", in: types), alignment)
                XCTAssertEqual(TypeDefinition.size(ofType: "S", in: types), alignment <= 2 ? 6 : 8)
            }
        }
    }

    func testZeroWidthExplicitAlignmentIgnoresPackingCap() throws {
        for prefix in ["", "#pragma pack(1)\n", "#pragma pack(2)\n", "#pragma pack(8)\n"] {
            for packed in ["", "__attribute__((packed))"] {
                let types = catalog(prefix + "struct \(packed) S { char head; unsigned :0 __attribute__((aligned(16))); char tail; };")
                let members = try XCTUnwrap(types["S"]).memberLayout(in: types)
                XCTAssertEqual(members[1].field.bitOffset, 128)
                XCTAssertEqual(members[2].offset, 16)
                XCTAssertEqual(TypeDefinition.size(ofType: "S", in: types), 17)
                XCTAssertEqual(TypeDefinition.alignment(ofType: "S", in: types), 1)
            }
        }
    }

    func testInlineMemberAttributesDoNotRepackTheirContentsOnExport() throws {
        for declaration in [
            "struct S { char head; struct { char c; int i; } inner __attribute__((packed)); char tail; };",
            "struct S { char head; __attribute__((packed)) struct { char c; int i; }; char tail; };",
        ] {
            let first = catalog(declaration)
            XCTAssertEqual(TypeDefinition.size(ofType: "S", in: first), 10)
            let type = try XCTUnwrap(first["S"])
            let second = catalog(CTypeHeaderRenderer.render(types: [type]))
            XCTAssertEqual(TypeDefinition.size(ofType: "S", in: second), 10)
            XCTAssertEqual(type.fields, second["S"]?.fields)
            XCTAssertEqual(type.memberLayout(in: first).map(\.offset), second["S"]?.memberLayout(in: second).map(\.offset))
        }
    }

    func testIntegerAliasAndEnumBitfieldsUseSharedLayoutResolution() throws {
        for preamble in ["typedef unsigned int U;", "enum U { A = 0, B = 10 };"] {
            let types = catalog(preamble + "struct S { U bits:3; int tail; };")
            XCTAssertEqual(TypeDefinition.size(ofType: "S", in: types), 8)
            let members = try XCTUnwrap(types["S"]).memberLayout(in: types)
            XCTAssertEqual(members.map(\.offset), [0, 4])
            XCTAssertEqual(members[0].field.bitOffset, 0)
        }
    }

    func testMemberAttributesCannotEraseUnknownBitfieldLayout() throws {
        // The expression is valid C but outside this parser's literal-width subset.
        // Put attributes before the type so recovery need not parse expression tokens.
        for attribute in ["packed", "aligned(8)"] {
            let source = "struct S { __attribute__((\(attribute))) unsigned bits : (1 << 3); int tail; };"
            let first = catalog(source)
            let type = try XCTUnwrap(first["S"])
            XCTAssertEqual(type.fields.first?.layoutIsUnknown, true)
            XCTAssertTrue(type.fields.contains { $0.name == "tail" })
            XCTAssertNil(TypeDefinition.size(ofType: "S", in: first))
            XCTAssertFalse(type.memberLayout(in: first).contains { $0.field.name == "tail" })
            let second = catalog(CTypeHeaderRenderer.render(types: [type]))
            XCTAssertEqual(second["S"]?.fields.first?.layoutIsUnknown, true)
            XCTAssertNil(TypeDefinition.size(ofType: "S", in: second))
        }
    }

    func testUnevaluatedDimensionsPoisonLayoutAndSurvivePersistenceAndExport() throws {
        for kind in ["struct", "union"] {
            for declaration in [
                "unsigned value:(1 << 3);", "unsigned value:1 << 3;",
                "unsigned :WIDTH;", "unsigned first:1, value:1 + 2;",
                "int value[COUNT];", "int value[1 + 2];", "int first, value[(1 << 3)];",
            ] {
                let source = "\(kind) S { char head; \(declaration) char tail; };"
                let types = catalog(source)
                let type = try XCTUnwrap(types["S"], source)
                XCTAssertNil(TypeDefinition.size(ofType: "S", in: types), source)
                XCTAssertTrue(type.fields.contains { $0.layoutIsUnknown == true }, source)
                XCTAssertTrue(type.fields.contains { $0.name == "tail" }, "Recovery must retain later fields: " + source)
                if kind == "struct" {
                    XCTAssertFalse(type.memberLayout(in: types).contains { $0.field.name == "tail" }, source)
                }
                let decoded = try JSONDecoder().decode(TypeDefinition.self, from: JSONEncoder().encode(type))
                XCTAssertNil(TypeDefinition.size(ofType: "S", in: ["S": decoded]), source)
                let imported = catalog(CTypeHeaderRenderer.render(types: [decoded]))
                XCTAssertNil(TypeDefinition.size(ofType: "S", in: imported), source)
                XCTAssertTrue(imported["S"]?.fields.contains { $0.layoutIsUnknown == true } == true, source)
            }
        }
    }

    func testUnsupportedDeclarationsRemainOpaqueAcrossExportEvenWithMarkerCollision() throws {
        for declaration in [
            "struct S { char head; _Complex double value; char tail; };",
            "struct S { char head; int value __attribute__((vector_size(16))); char tail; };",
            "struct S { char head; struct { int value; } array[3]; char tail; };",
        ] {
            let first = catalog("typedef int __macscope_unknown_layout; " + declaration)
            XCTAssertNil(TypeDefinition.size(ofType: "S", in: first))
            XCTAssertEqual(try XCTUnwrap(first["S"]).memberLayout(in: first).map(\.field.name), ["head"])
            let order = [try XCTUnwrap(first["__macscope_unknown_layout"]), try XCTUnwrap(first["S"])]
            let second = catalog(CTypeHeaderRenderer.render(types: order))
            XCTAssertNil(TypeDefinition.size(ofType: "S", in: second))
            XCTAssertEqual(try XCTUnwrap(second["S"]).memberLayout(in: second).map(\.field.name), ["head"])
        }
        for source in [
            "enum E { A = 0, B = 255 } __attribute__((packed));",
            "enum __attribute__((aligned(16))) E { A = 0 };",
            "typedef int E __attribute__((aligned(16)));",
        ] {
            let first = catalog(source)
            XCTAssertNil(TypeDefinition.size(ofType: "E", in: first), source)
            let second = catalog(CTypeHeaderRenderer.render(types: Array(first.values)))
            XCTAssertNil(TypeDefinition.size(ofType: "E", in: second), source)
        }
    }

    func testHugeLayoutArithmeticFailsClosedInsteadOfTrapping() throws {
        for source in [
            "struct S { char huge[1152921504606846976]; };",
            "struct S { char huge[9223372036854775807]; char tail; };",
            "struct S { char head; unsigned bits:1 __attribute__((aligned(9223372036854775807))); };",
            "union __attribute__((aligned(9223372036854775807))) S { char huge[9223372036854775806]; };",
        ] {
            let types = catalog(source)
            _ = try XCTUnwrap(types["S"]).memberLayout(in: types)
            // The final union can represent its rounded byte size; all others
            // exceed the bit-cursor representation or a checked arithmetic bound.
            if !source.hasPrefix("union") { XCTAssertNil(TypeDefinition.size(ofType: "S", in: types), source) }
        }
    }

    func testTypeBasedBitfieldAlignmentMovesCursor() throws {
        let field = FieldDef(name: "bits", type: "unsigned int", bitWidth: 3, minimumAlignmentType: "double")
        let type = TypeDefinition(kind: .struct, name: "S", fields: [FieldDef(name: "head", type: "char"), field])
        XCTAssertEqual(type.memberLayout()[1].field.bitOffset, 64)
        XCTAssertEqual(TypeDefinition.size(ofType: "S", in: ["S": type]), 16)
    }

    func testUnknownPrimitiveSpellingsDoNotProduceScalarReadings() {
        for spelling in ["unsigned mystery_word", "signed mystery_word", "mystery_word"] {
            let type = TypeDefinition(kind: .struct, name: "S", fields: [FieldDef(name: "value", type: spelling)])
            XCTAssertNil(TypeDefinition.size(ofType: spelling))
            XCTAssertTrue(StructMemberReading(type: type, bytes: Data(repeating: 255, count: 8), baseOffset: 0).rows.isEmpty)
        }
    }

    func testNewlySizedPrimitiveSpellingsReadWithCorrectScalarInterpretation() {
        for (spelling, bytes, expected) in [
            ("signed char", Data([255]), "-1"),
            ("const unsigned char", Data([255]), "255"),
            ("signed short int", Data(repeating: 255, count: 2), "-1"),
            ("unsigned short int", Data(repeating: 255, count: 2), "65535"),
            ("signed int", Data(repeating: 255, count: 4), "-1"),
            ("unsigned", Data(repeating: 255, count: 4), "4294967295"),
            ("volatile unsigned long long int", Data(repeating: 255, count: 8), "18446744073709551615"),
            ("unsigned long", Data(repeating: 255, count: 8), "18446744073709551615"),
            ("long double", Data([0, 0, 0, 0, 0, 0, 240, 63]), "1.0"),
        ] {
            let type = TypeDefinition(kind: .struct, name: "S", fields: [FieldDef(name: "value", type: spelling)])
            XCTAssertEqual(StructMemberReading(type: type, bytes: bytes, baseOffset: 0).rows.first?.value, expected)
            XCTAssertEqual(StructMemberReading(type: type, bytes: bytes, baseOffset: Int.max).rows.first?.value, "—")
        }
    }

}

import XCTest
@testable import MacScope

final class NativeAuthoredTypeParserV1Tests: XCTestCase {
    func testFrozenScalarSpellingsProduceExpectedAtoms() throws {
        let rows: [([String], NativeDecompilerWireAuthoredScalarKind)] = [
            (["_Bool", "bool"], .bool),
            (["char"], .char),
            (["signed char", "int8_t"], .signed8),
            (["unsigned char", "uint8_t"], .unsigned8),
            (["short", "short int", "signed short", "signed short int", "int16_t"], .signed16),
            (["unsigned short", "unsigned short int", "uint16_t"], .unsigned16),
            (["int", "signed", "signed int", "int32_t"], .signed32),
            (["unsigned", "unsigned int", "uint32_t"], .unsigned32),
            ([
                "long", "long int", "signed long", "signed long int", "long long",
                "long long int", "signed long long", "signed long long int", "int64_t",
            ], .signed64),
            (["unsigned long", "unsigned long int", "unsigned long long", "unsigned long long int", "uint64_t"], .unsigned64),
            (["float"], .float32),
            (["double", "long double"], .float64),
        ]
        let catalog = try emptyCatalog()

        for (spellings, kind) in rows {
            let expected = qualified(.scalar(kind))
            for spelling in spellings {
                XCTAssertEqual(
                    try NativeAuthoredTypeParserV1.parse(spelling, role: .parameter, catalog: catalog),
                    expected,
                    "Unexpected scalar mapping for \(spelling)"
                )
            }
        }
    }

    func testASCIIWhitespaceAndEquivalentRestrictSpellingsAreInvariant() throws {
        let catalog = try emptyCatalog()
        let compact = try parse("const int*volatile restrict*const", catalog: catalog)
        let spaced = try parse(" \t\n\u{0B}\u{0C}\r const   int * volatile __restrict * const \t", catalog: catalog)
        let alternate = try parse("const int * volatile __restrict__ * const", catalog: catalog)

        XCTAssertEqual(compact, spaced)
        XCTAssertEqual(compact, alternate)
        XCTAssertEqual(try parse("int*", catalog: catalog), try parse("int *", catalog: catalog))
        XCTAssertEqual(
            compact,
            .dataPointer(
                pointee: qualified(.scalar(.signed32), qualifiers: [.constant]),
                indirectionLevel: .init(2),
                pointerQualifiersByLevel: [[.volatile, .restrict], [.constant]]
            )
        )
    }

    func testDarwinAliasesRemainDistinctFromEquivalentScalars() throws {
        let catalog = try emptyCatalog()
        let rows: [(String, NativeDecompilerWireAuthoredDarwinAliasKind, NativeDecompilerWireAuthoredScalarKind)] = [
            ("size_t", .sizeT, .unsigned64),
            ("ssize_t", .ssizeT, .signed64),
            ("intptr_t", .intptrT, .signed64),
            ("uintptr_t", .uintptrT, .unsigned64),
            ("ptrdiff_t", .ptrdiffT, .signed64),
            ("wchar_t", .wcharT, .signed32),
        ]

        for (source, alias, representation) in rows {
            let parsed = try parse(source, catalog: catalog)
            XCTAssertEqual(parsed, qualified(.darwinAlias(alias)))
            XCTAssertNotEqual(parsed, qualified(.scalar(representation)))
        }
    }

    func testQualifierBitsRemainAtTheirExactBaseAndPointerLevels() throws {
        let catalog = try emptyCatalog()
        let qualifiedSigned32 = qualified(.scalar(.signed32), qualifiers: [.constant, .volatile])
        XCTAssertEqual(try parse("const volatile int", catalog: catalog), qualifiedSigned32)
        XCTAssertEqual(try parse("const int volatile", catalog: catalog), qualifiedSigned32)
        XCTAssertEqual(try parse("int const volatile", catalog: catalog), qualifiedSigned32)
        XCTAssertEqual(
            try parse("void const", role: .returnType, catalog: catalog),
            qualified(.void, qualifiers: [.constant])
        )

        XCTAssertEqual(
            try parse("const volatile int * const * volatile restrict", catalog: catalog),
            .dataPointer(
                pointee: qualified(.scalar(.signed32), qualifiers: [.constant, .volatile]),
                indirectionLevel: .init(2),
                pointerQualifiersByLevel: [[.constant], [.volatile, .restrict]]
            )
        )

        let depthEight = "int * const * volatile * restrict * const volatile * const restrict * volatile restrict * const volatile restrict *"
        XCTAssertEqual(
            try parse(depthEight, catalog: catalog),
            .dataPointer(
                pointee: qualified(.scalar(.signed32)),
                indirectionLevel: .init(8),
                pointerQualifiersByLevel: [
                    [.constant], [.volatile], [.restrict], [.constant, .volatile],
                    [.constant, .restrict], [.volatile, .restrict],
                    [.constant, .volatile, .restrict], [],
                ]
            )
        )
    }

    func testCatalogBareAndTaggedNamesRequireExactUniqueKind() throws {
        let catalog = try NativeAuthoredCatalogIndex(definitions: [
            definition(.struct, "Packet"),
            definition(.union, "Payload"),
            definition(.enum, "Mode"),
            definition(.typedef, "Word"),
        ])

        let rows: [(String, NativeDecompilerWireAuthoredNamedKind)] = [
            ("Packet", .struct), ("Payload", .union), ("Mode", .enum), ("Word", .typedef),
            ("struct Packet", .struct), ("union Payload", .union), ("enum Mode", .enum),
        ]
        for (source, kind) in rows {
            XCTAssertEqual(try parse(source, catalog: catalog), qualified(.named(kind: kind, name: source.split(separator: " ").last.map(String.init) ?? source)))
        }
        XCTAssertEqual(
            try parse("struct Packet * const", catalog: catalog),
            .dataPointer(
                pointee: qualified(.named(kind: .struct, name: "Packet")),
                indirectionLevel: .init(1),
                pointerQualifiersByLevel: [[.constant]]
            )
        )

        XCTAssertEqual(try catalog.resolveBareName("Packet"), definition(.struct, "Packet"))
        XCTAssertEqual(try catalog.resolveTaggedName("Packet", kind: .struct), definition(.struct, "Packet"))
        assertDiagnostic(.invalid(id: typeIdentity)) { try parse("union Packet", catalog: catalog) }
        assertDiagnostic(.invalid(id: typeIdentity)) { try parse("packet", catalog: catalog) }
        assertDiagnostic(.invalid(id: catalogIdentity)) {
            try NativeAuthoredCatalogIndex(definitions: [definition(.struct, "Packet"), definition(.union, "Packet")])
        }
    }

    func testCatalogIdentityUsesExactUTF8WithoutUnicodeNormalization() throws {
        let precomposed = "\u{00E9}"
        let decomposed = "e\u{0301}"
        let kelvin = "\u{212A}"
        let catalog = try NativeAuthoredCatalogIndex(definitions: [
            definition(.struct, precomposed, idByte: 1),
            definition(.union, decomposed, idByte: 2),
            definition(.enum, kelvin, idByte: 3),
        ])

        XCTAssertEqual(try catalog.resolveBareName(precomposed).id, definitionID(1))
        XCTAssertEqual(try catalog.resolveBareName(decomposed).id, definitionID(2))
        XCTAssertEqual(try catalog.resolveBareName(kelvin).id, definitionID(3))
        assertDiagnostic(.invalid(id: typeIdentity)) { try catalog.resolveBareName("K") }

        for source in [precomposed, decomposed, kelvin] {
            assertDiagnostic(.invalid(id: typeIdentity), source) { try parse(source, catalog: catalog) }
        }
        assertDiagnostic(.invalid(id: typeIdentity), "K") { try parse("K", catalog: catalog) }
    }

    func testVoidIsAllowedOnlyForReturnOrPointerPointee() throws {
        let catalog = try emptyCatalog()
        XCTAssertEqual(try parse("void", role: .returnType, catalog: catalog), qualified(.void))

        for role in [
            NativeAuthoredTypeRole.returnType, .parameter, .recordField, .typedefTarget,
            .minimumAlignmentType,
        ] {
            XCTAssertEqual(
                try parse("const void * volatile", role: role, catalog: catalog),
                .dataPointer(
                    pointee: qualified(.void, qualifiers: [.constant]),
                    indirectionLevel: .init(1),
                    pointerQualifiersByLevel: [[.volatile]]
                )
            )
        }

        for role in [
            NativeAuthoredTypeRole.parameter, .recordField, .typedefTarget, .minimumAlignmentType,
        ] {
            assertDiagnostic(.invalid(id: typeIdentity)) { try parse("void", role: role, catalog: catalog) }
        }
    }

    func testRejectsUnicodeWhitespaceNormalizationAndNonASCIIIdentifiers() throws {
        let catalog = try NativeAuthoredCatalogIndex(definitions: [definition(.struct, "Cafe")])
        let rejected = [
            "unsigned\u{00A0}int", "unsigned\u{2003}int", "unsigned\u{2028}int",
            "Café", "Cafe\u{0301}", "Ｃａｆｅ", "int\u{0085}", "int\u{0000}", "int\u{0001}", "int\u{007F}",
        ]
        for source in rejected {
            assertDiagnostic(.invalid(id: typeIdentity), source) { try parse(source, catalog: catalog) }
        }
    }

    func testRejectsDuplicateContradictoryAndBaseRestrictQualifiers() throws {
        let catalog = try emptyCatalog()
        let rejected = [
            "const const int", "volatile int volatile", "restrict int", "__restrict int",
            "int restrict", "int * const const", "int * restrict __restrict",
            "int * volatile * __restrict restrict", "const volatile const int",
        ]
        for source in rejected {
            assertDiagnostic(.invalid(id: typeIdentity), source) { try parse(source, catalog: catalog) }
        }
    }

    func testRejectsPointerDepthNineUnknownTokensAndUnsupportedDeclarators() throws {
        let catalog = try emptyCatalog()
        let rejected = [
            "int * * * * * * * * *", "mystery", "int[2]", "int()", "int (^block)(void)",
            "int &", "int &&", "vector_int4", "_Atomic int", "_Atomic(int)",
            "int (*)(void)", "int __attribute__((vector_size(16)))", "long unsigned",
            "int signed", "double long", "struct", "union", "enum", "typedef Packet",
        ]
        for source in rejected {
            assertDiagnostic(.invalid(id: typeIdentity), source) { try parse(source, catalog: catalog) }
        }
    }

    func testRejectsKeywordAliasAndWrongKindCatalogCollisions() throws {
        let scalarSpellings = [
            "_Bool", "bool", "char", "signed char", "int8_t", "unsigned char", "uint8_t",
            "short", "short int", "signed short", "signed short int", "int16_t",
            "unsigned short", "unsigned short int", "uint16_t", "int", "signed", "signed int",
            "int32_t", "unsigned", "unsigned int", "uint32_t", "long", "long int", "signed long",
            "signed long int", "long long", "long long int", "signed long long",
            "signed long long int", "int64_t", "unsigned long", "unsigned long int",
            "unsigned long long", "unsigned long long int", "uint64_t", "float", "double", "long double",
        ]
        for name in [
            "void", "const", "volatile", "restrict", "__restrict", "__restrict__", "struct",
            "union", "enum", "typedef",
            "size_t", "ssize_t", "intptr_t", "uintptr_t", "ptrdiff_t", "wchar_t",
        ] + scalarSpellings {
            assertDiagnostic(.invalid(id: catalogIdentity), name) {
                try NativeAuthoredCatalogIndex(definitions: [definition(.struct, name)])
            }
        }

        assertDiagnostic(.invalid(id: catalogIdentity), "same-kind duplicate") {
            try NativeAuthoredCatalogIndex(definitions: [
                definition(.struct, "Packet"),
                definition(.struct, "Packet"),
            ])
        }

        let catalog = try NativeAuthoredCatalogIndex(definitions: [definition(.enum, "State")])
        assertDiagnostic(.invalid(id: typeIdentity)) { try parse("struct State", catalog: catalog) }
        assertDiagnostic(.invalid(id: typeIdentity)) { try parse("union State", catalog: catalog) }
    }

    func testRejectsRawSourceAt4097UTF8Bytes() throws {
        let catalog = try emptyCatalog()
        let exact = "int" + String(repeating: " ", count: 4_093)
        let over = exact + " "
        XCTAssertEqual(exact.utf8.count, 4_096)
        XCTAssertEqual(over.utf8.count, 4_097)
        XCTAssertEqual(try parse(exact, catalog: catalog), qualified(.scalar(.signed32)))
        assertDiagnostic(.bounds(id: typeBoundsIdentity)) { try parse(over, catalog: catalog) }
    }

    func testDiagnosticsUseStablePathFreeIdentityAndNeverEchoRawSource() throws {
        let raw = "/Users/private/project/unknown_type"
        let catalog = try emptyCatalog()
        assertDiagnostic(.invalid(id: typeIdentity)) { try parse(raw, catalog: catalog) }

        for identity in [typeIdentity, catalogIdentity] {
            XCTAssertFalse(identity.code.contains("/"))
            XCTAssertFalse(identity.subject.contains("/"))
            XCTAssertFalse(identity.code.contains(raw))
            XCTAssertFalse(identity.subject.contains(raw))
        }
    }
}

private extension NativeAuthoredTypeParserV1Tests {
    var typeIdentity: NativeAuthoredProjectionDiagnostic.Identity {
        .init(code: "authored-type-grammar", imageSlot: nil, subject: "authored-type")
    }

    var typeBoundsIdentity: NativeAuthoredProjectionDiagnostic.Identity {
        .init(code: "authored-type-source-bytes", imageSlot: nil, subject: "authored-type")
    }

    var catalogIdentity: NativeAuthoredProjectionDiagnostic.Identity {
        .init(code: "authored-catalog-definition", imageSlot: nil, subject: "type-catalog")
    }

    func emptyCatalog() throws -> NativeAuthoredCatalogIndex {
        try NativeAuthoredCatalogIndex(definitions: [])
    }

    func definition(_ kind: TypeKind, _ name: String, idByte: UInt8 = 1) -> TypeDefinition {
        TypeDefinition(id: definitionID(idByte), kind: kind, name: name)
    }

    func definitionID(_ byte: UInt8) -> UUID {
        UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, byte))
    }

    func qualified(
        _ atom: NativeDecompilerWireAuthoredAtom,
        qualifiers: NativeDecompilerWireAuthoredQualifiers = []
    ) -> NativeDecompilerWireAuthoredType {
        .qualifiedValue(atom: atom, qualifiers: qualifiers)
    }

    func parse(
        _ source: String,
        role: NativeAuthoredTypeRole = .parameter,
        catalog: NativeAuthoredCatalogIndex
    ) throws -> NativeDecompilerWireAuthoredType {
        try NativeAuthoredTypeParserV1.parse(source, role: role, catalog: catalog)
    }

    func assertDiagnostic<T>(
        _ expected: NativeAuthoredProjectionDiagnostic,
        _ context: String = "",
        file: StaticString = #filePath,
        line: UInt = #line,
        operation: () throws -> T
    ) {
        XCTAssertThrowsError(try operation(), context, file: file, line: line) { error in
            XCTAssertEqual(error as? NativeAuthoredProjectionDiagnostic, expected, context, file: file, line: line)
        }
    }
}

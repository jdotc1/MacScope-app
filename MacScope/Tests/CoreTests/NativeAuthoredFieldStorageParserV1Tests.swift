import XCTest
@testable import MacScope

final class NativeAuthoredFieldStorageParserV1Tests: XCTestCase {
    func testPeelsMultidimensionalFixedArraysFromRightToLeft() throws {
        let storage = try parse(field("matrix", "uint8_t[2][3]"), owner: .struct)
        XCTAssertEqual(
            storage,
            .fixedArray(
                element: .fixedArray(element: byteValue, count: .init(3)),
                count: .init(2)
            )
        )
        XCTAssertEqual(
            try parse(field("matrix", " uint8_t [ 2 ] [ 3 ] "), owner: .struct),
            storage
        )
    }

    func testAcceptsFlexibleArrayOnlyAsFinalStructField() throws {
        XCTAssertEqual(
            try parse(field("tail", "uint8_t[]"), owner: .struct, index: 1, count: 2),
            .flexibleArray(element: byteValue)
        )
        assertInvalid { try parse(field("tail", "uint8_t[]"), owner: .struct, index: 0, count: 2) }
        assertInvalid { try parse(field("tail", "uint8_t[]"), owner: .union) }
        assertInvalid { try parse(field("tail", "uint8_t[]"), owner: .typedef) }
        assertInvalid { try parse(field("tail", "uint8_t[2][]"), owner: .struct) }

        XCTAssertEqual(
            try parse(field("rows", "uint8_t[][2]"), owner: .struct),
            .flexibleArray(element: .fixedArray(element: byteValue, count: .init(2)))
        )
    }

    func testProjectsEveryCarrierFromDurableProvenance() throws {
        XCTAssertEqual(
            try parse(field("callback", "int32_t *", semantics: .functionPointerCarrier), owner: .struct),
            .opaquePointerCarrier(kind: .functionPointer)
        )
        XCTAssertEqual(
            try parse(field("buffer", "int32_t *", semantics: .pointerToArrayCarrier), owner: .struct),
            .opaquePointerCarrier(kind: .pointerToArray)
        )
        XCTAssertEqual(
            try parse(field("ordinary", "int32_t *", semantics: .ordinary), owner: .struct),
            .value(
                .dataPointer(
                    pointee: signed32Type,
                    indirectionLevel: .init(1),
                    pointerQualifiersByLevel: [[]]
                )
            )
        )
    }

    func testRejectsInlineMetadataThatContradictsDeclaratorProvenance() throws {
        for semantics in [
            FieldDef.DeclaratorSemanticsV1.functionPointerCarrier,
            .pointerToArrayCarrier,
            .arrayOfFunctionPointerCarrier,
        ] {
            var candidate = inlineField(
                name: "contradictory",
                kind: .struct,
                fields: [field("member", "int")]
            )
            candidate.declaratorSemanticsV1 = semantics
            assertInvalid { try parse(candidate, owner: .struct) }
        }

        var legacy = inlineField(
            name: "legacy",
            kind: .struct,
            fields: [field("member", "int")]
        )
        legacy.declaratorSemanticsV1 = nil
        assertDiagnostic(.unsupported(id: unsupportedFieldIdentity)) {
            try parse(legacy, owner: .struct)
        }
    }

    func testWrapsArrayOfFunctionPointerCarrierInPersistedDimensions() throws {
        XCTAssertEqual(
            try parse(field("callbacks", "int32_t *[2][3]", semantics: .arrayOfFunctionPointerCarrier), owner: .struct),
            .fixedArray(
                element: .fixedArray(
                    element: .opaquePointerCarrier(kind: .functionPointer),
                    count: .init(3)
                ),
                count: .init(2)
            )
        )
        assertInvalid {
            try parse(field("callbacks", "int32_t *", semantics: .arrayOfFunctionPointerCarrier), owner: .struct)
        }
        assertInvalid {
            try parse(field("callbacks", "int32_t *[]", semantics: .arrayOfFunctionPointerCarrier), owner: .struct)
        }
    }

    func testProjectsInlineAggregateWithoutPlaceholderTypeAuthority() throws {
        let nested = FieldDef(
            name: "",
            type: "/not/a/type[999999999999999999999999]",
            declaratorSemanticsV1: .ordinary,
            inlineAggregateKind: .struct,
            inlineFields: [
                FieldDef(
                    name: "bits",
                    type: "unsigned int",
                    declaratorSemanticsV1: .ordinary,
                    bitWidth: 3,
                    minimumAlignment: 4,
                    minimumAlignmentType: "uint32_t"
                ),
                FieldDef(
                    name: "tag",
                    type: "uint8_t",
                    declaratorSemanticsV1: .ordinary
                ),
            ],
            inlineAggregateLayoutRules: .init(isPacked: true, packAlignment: 2, minimumAlignment: 8),
            promotesInlineFields: true
        )

        XCTAssertEqual(
            try parse(nested, owner: .struct),
            .inlineAggregate(
                kind: .struct,
                layoutRules: .init(isPacked: true, packAlignment: .init(2), minimumAlignment: .init(8)),
                fields: [
                    .init(
                        name: "bits",
                        storage: .value(qualified(.scalar(.unsigned32))),
                        bitWidth: .init(3),
                        minimumAlignment: .init(4),
                        minimumAlignmentType: qualified(.scalar(.unsigned32)),
                        promotesInlineFields: false
                    ),
                    .init(
                        name: "tag",
                        storage: byteValue,
                        bitWidth: nil,
                        minimumAlignment: nil,
                        minimumAlignmentType: nil,
                        promotesInlineFields: false
                    ),
                ]
            )
        )
    }

    func testQuarantinesPointerShapedLegacyFieldWithoutProvenance() throws {
        for source in ["int*", "int *", "const int * volatile", "Packet **"] {
            assertDiagnostic(.unsupported(id: unsupportedFieldIdentity), source) {
                try parse(field("legacy", source, semantics: nil), owner: .struct)
            }
        }
    }

    func testAllowsUnambiguousLegacyNonpointerValueAndArray() throws {
        XCTAssertEqual(try parse(field("legacy", "int32_t", semantics: nil), owner: .struct), .value(signed32Type))
        XCTAssertEqual(
            try parse(field("legacy", "int32_t[2][3]", semantics: nil), owner: .struct),
            .fixedArray(
                element: .fixedArray(element: .value(signed32Type), count: .init(3)),
                count: .init(2)
            )
        )
    }

    func testRejectsZeroNegativeOverflowAnd1048577ElementDimensions() throws {
        XCTAssertEqual(
            try parse(field("maximum", "uint8_t[1048576]"), owner: .struct),
            .fixedArray(element: byteValue, count: .init(1_048_576))
        )
        for source in [
            "uint8_t[0]", "uint8_t[-1]", "uint8_t[1048577]",
            "uint8_t[18446744073709551616]", "uint8_t[1x]", "uint8_t[+1]",
        ] {
            let diagnostic: NativeAuthoredProjectionDiagnostic = source == "uint8_t[1048577]"
                ? .bounds(id: boundsFieldIdentity)
                : .invalid(id: invalidFieldIdentity)
            assertDiagnostic(diagnostic, source) { try parse(field("bad", source), owner: .struct) }
        }
    }

    func testRejectsInvalidFieldPositionsBeforeParsingStorage() throws {
        let valid = field("value", "int32_t")
        for position in [
            NativeAuthoredFieldPosition(ownerKind: .struct, index: -1, count: 1),
            .init(ownerKind: .struct, index: 0, count: 0),
            .init(ownerKind: .struct, index: 1, count: 1),
            .init(ownerKind: .enum, index: 0, count: 1),
            .init(ownerKind: .typedef, index: 0, count: 2),
        ] {
            assertInvalid { try parse(valid, position: position) }
        }
        XCTAssertNoThrow(try parse(valid, position: .init(ownerKind: .typedef, index: 0, count: 1)))
    }

    func testFlexibleArrayPlacementPropagatesOnlyThroughFinalInlineStructs() throws {
        let directTail = field("tail", "uint8_t[]")
        let finalStruct = inlineField(name: "payload", kind: .struct, fields: [field("head", "uint8_t"), directTail])
        XCTAssertNoThrow(try parse(finalStruct, owner: .struct))
        assertInvalid { try parse(finalStruct, owner: .union) }
        assertInvalid { try parse(finalStruct, owner: .typedef) }

        let nonfinalInner = inlineField(name: "payload", kind: .struct, fields: [directTail, field("sentinel", "uint8_t")])
        assertInvalid { try parse(nonfinalInner, owner: .struct) }

        let unionBarrier = inlineField(name: "payload", kind: .union, fields: [directTail])
        assertInvalid { try parse(unionBarrier, owner: .struct) }

        let nonfinalOuter = inlineField(name: "payload", kind: .struct, fields: [directTail])
        assertInvalid { try parse(nonfinalOuter, owner: .struct, index: 0, count: 2) }

        let fixedArrayBarrier = field("rows", "uint8_t[2][]")
        assertInvalid { try parse(fixedArrayBarrier, owner: .struct) }
    }

    func testDepthSixteenIsAcceptedAndEverySeventeenthEdgeRejects() throws {
        let arraysAtMaximum = field("deep", "uint8_t" + String(repeating: "[1]", count: 16))
        XCTAssertNoThrow(try parse(arraysAtMaximum, owner: .struct))
        assertBounds {
            try parse(field("deep", "uint8_t" + String(repeating: "[1]", count: 17)), owner: .struct)
        }

        XCTAssertNoThrow(
            try parse(field("deepPointer", "int *" + String(repeating: "[1]", count: 15)), owner: .struct)
        )
        assertBounds {
            try parse(field("deepPointer", "int *" + String(repeating: "[1]", count: 16)), owner: .struct)
        }

        XCTAssertNoThrow(try parse(nestedInline(depth: 16), owner: .struct))
        assertBounds { try parse(nestedInline(depth: 17), owner: .struct) }

        XCTAssertNoThrow(try parse(nestedInlineWithPointerAlignment(depth: 14), owner: .struct))
        assertBounds { try parse(nestedInlineWithPointerAlignment(depth: 15), owner: .struct) }
    }

    func testAnonymousBitfieldAndPromotionShapesMatchWireInvariants() throws {
        XCTAssertNoThrow(try parse(field("", "unsigned int", bitWidth: 0), owner: .struct))
        XCTAssertNoThrow(try parse(field("", "unsigned int", bitWidth: 7), owner: .struct))
        XCTAssertNoThrow(
            try parse(inlineField(name: "", kind: .union, fields: [field("member", "int")], promotes: true), owner: .struct)
        )

        let invalid: [FieldDef] = [
            field("", "unsigned int"),
            field("named", "unsigned int", bitWidth: 0),
            field("named", "unsigned int[2]", bitWidth: 3),
            field("named", "int32_t *", semantics: .functionPointerCarrier, bitWidth: 3),
            inlineField(name: "", kind: .struct, fields: [field("member", "int")]),
            inlineField(name: "named", kind: .struct, fields: [field("member", "int")], promotes: true),
            FieldDef(name: "named", type: "int", declaratorSemanticsV1: .ordinary, promotesInlineFields: true),
            FieldDef(name: "", type: "ignored", declaratorSemanticsV1: .ordinary, bitWidth: 1, inlineAggregateKind: .struct, inlineFields: [field("member", "int")], promotesInlineFields: true),
        ]
        for candidate in invalid {
            assertInvalid { try parse(candidate, owner: .struct) }
        }

        var negativeWidth = field("bad", "unsigned int", bitWidth: 1)
        negativeWidth.bitWidth = -1
        assertInvalid { try parse(negativeWidth, owner: .struct) }
    }

    func testInlineEnumTypedefAndMalformedMetadataFailClosed() throws {
        for kind in [TypeKind.enum, .typedef] {
            assertInvalid {
                try parse(inlineField(name: "bad", kind: kind, fields: [field("member", "int")]), owner: .struct)
            }
        }

        var badAlignment = field("bad", "int")
        badAlignment.minimumAlignment = -1
        assertInvalid { try parse(badAlignment, owner: .struct) }

        var badLayout = inlineField(name: "bad", kind: .struct, fields: [field("member", "int")])
        badLayout.inlineAggregateLayoutRules.packAlignment = -1
        assertInvalid { try parse(badLayout, owner: .struct) }
    }

    func testDiagnosticsUseStablePathFreeCodes() throws {
        for identity in [invalidFieldIdentity, boundsFieldIdentity, unsupportedFieldIdentity] {
            XCTAssertFalse(identity.code.contains("/"))
            XCTAssertFalse(identity.subject.contains("/"))
        }
        XCTAssertEqual(invalidFieldIdentity.code, "authored-field-storage")
        XCTAssertEqual(boundsFieldIdentity.code, "authored-field-storage-bounds")
        XCTAssertEqual(unsupportedFieldIdentity.code, "authoring-input-unsupported")
    }
}

private extension NativeAuthoredFieldStorageParserV1Tests {
    var invalidFieldIdentity: NativeAuthoredProjectionDiagnostic.Identity {
        .init(code: "authored-field-storage", imageSlot: nil, subject: "record-field")
    }

    var boundsFieldIdentity: NativeAuthoredProjectionDiagnostic.Identity {
        .init(code: "authored-field-storage-bounds", imageSlot: nil, subject: "record-field")
    }

    var unsupportedFieldIdentity: NativeAuthoredProjectionDiagnostic.Identity {
        .init(code: "authoring-input-unsupported", imageSlot: nil, subject: "record-field")
    }

    var signed32Type: NativeDecompilerWireAuthoredType { qualified(.scalar(.signed32)) }
    var byteValue: NativeDecompilerWireAuthoredFieldStorage { .value(qualified(.scalar(.unsigned8))) }

    func qualified(
        _ atom: NativeDecompilerWireAuthoredAtom,
        qualifiers: NativeDecompilerWireAuthoredQualifiers = []
    ) -> NativeDecompilerWireAuthoredType {
        .qualifiedValue(atom: atom, qualifiers: qualifiers)
    }

    func field(
        _ name: String,
        _ type: String,
        semantics: FieldDef.DeclaratorSemanticsV1? = .ordinary,
        bitWidth: Int? = nil
    ) -> FieldDef {
        FieldDef(name: name, type: type, declaratorSemanticsV1: semantics, bitWidth: bitWidth)
    }

    func inlineField(
        name: String,
        kind: TypeKind,
        fields: [FieldDef],
        promotes: Bool = false
    ) -> FieldDef {
        FieldDef(
            name: name,
            type: "ignored-inline-placeholder",
            declaratorSemanticsV1: .ordinary,
            inlineAggregateKind: kind,
            inlineFields: fields,
            promotesInlineFields: promotes
        )
    }

    func nestedInline(depth: Int) -> FieldDef {
        precondition(depth > 0)
        var nested = field("leaf", "uint8_t")
        for index in 0..<depth {
            nested = inlineField(name: "level\(index)", kind: .struct, fields: [nested])
        }
        return nested
    }

    func nestedInlineWithPointerAlignment(depth: Int) -> FieldDef {
        precondition(depth > 0)
        var nested = FieldDef(
            name: "leaf",
            type: "uint8_t",
            declaratorSemanticsV1: .ordinary,
            minimumAlignmentType: "int *"
        )
        for index in 0..<depth {
            nested = inlineField(name: "level\(index)", kind: .struct, fields: [nested])
        }
        return nested
    }

    func parse(
        _ field: FieldDef,
        owner: TypeKind,
        index: Int = 0,
        count: Int = 1
    ) throws -> NativeDecompilerWireAuthoredFieldStorage {
        try parse(field, position: .init(ownerKind: owner, index: index, count: count))
    }

    func parse(
        _ field: FieldDef,
        position: NativeAuthoredFieldPosition
    ) throws -> NativeDecompilerWireAuthoredFieldStorage {
        try NativeAuthoredFieldStorageParserV1.parse(
            field: field,
            position: position,
            catalog: NativeAuthoredCatalogIndex(definitions: [
                TypeDefinition(kind: .struct, name: "Packet"),
            ])
        )
    }

    func assertInvalid<T>(
        file: StaticString = #filePath,
        line: UInt = #line,
        operation: () throws -> T
    ) {
        assertDiagnostic(.invalid(id: invalidFieldIdentity), file: file, line: line, operation: operation)
    }

    func assertBounds<T>(
        file: StaticString = #filePath,
        line: UInt = #line,
        operation: () throws -> T
    ) {
        assertDiagnostic(.bounds(id: boundsFieldIdentity), file: file, line: line, operation: operation)
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

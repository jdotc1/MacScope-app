import CoreFoundation
import Foundation
import XCTest
@testable import MacScope

final class NativeDecompilerWireAuthoredModelsTests: XCTestCase {
    func testStandaloneAuthenticationEffectDecodesWithoutInventedOutput() throws {
        let data = Data(#"{"kind":"standalone-authentication-without-transformed-output"}"#.utf8)
        let effect = try JSONDecoder().decode(NativeDecompilerWireAuthenticationEffect.self, from: data)
        XCTAssertEqual(effect.kind.rawValue, "standalone-authentication-without-transformed-output")
        XCTAssertNil(effect.outputSSAValueID)
    }

    func testRewrittenGraphDiscriminatorsAreExplicit() throws {
        XCTAssertNoThrow(try JSONDecoder().decode(
            NativeDecompilerWireBlockTerminatorKind.self, from: Data(#""splice""#.utf8)))
        XCTAssertNoThrow(try JSONDecoder().decode(
            NativeDecompilerWireEdgeKind.self, from: Data(#""splice""#.utf8)))
    }

    func testFrozenTagRegistryAndNoReturnTriState() throws {
        XCTAssertEqual(NativeDecompilerWireAuthoredTypeTag.qualifiedValue.rawValue, 0)
        XCTAssertEqual(NativeDecompilerWireAuthoredTypeTag.dataPointer.rawValue, 1)

        XCTAssertEqual(NativeDecompilerWireAuthoredAtomTag.void.rawValue, 0)
        XCTAssertEqual(NativeDecompilerWireAuthoredAtomTag.scalar.rawValue, 1)
        XCTAssertEqual(NativeDecompilerWireAuthoredAtomTag.darwinAlias.rawValue, 2)
        XCTAssertEqual(NativeDecompilerWireAuthoredAtomTag.named.rawValue, 3)

        XCTAssertEqual(NativeDecompilerWireAuthoredScalarKind.bool.rawValue, 0)
        XCTAssertEqual(NativeDecompilerWireAuthoredScalarKind.char.rawValue, 1)
        XCTAssertEqual(NativeDecompilerWireAuthoredScalarKind.signed8.rawValue, 2)
        XCTAssertEqual(NativeDecompilerWireAuthoredScalarKind.unsigned8.rawValue, 3)
        XCTAssertEqual(NativeDecompilerWireAuthoredScalarKind.signed16.rawValue, 4)
        XCTAssertEqual(NativeDecompilerWireAuthoredScalarKind.unsigned16.rawValue, 5)
        XCTAssertEqual(NativeDecompilerWireAuthoredScalarKind.signed32.rawValue, 6)
        XCTAssertEqual(NativeDecompilerWireAuthoredScalarKind.unsigned32.rawValue, 7)
        XCTAssertEqual(NativeDecompilerWireAuthoredScalarKind.signed64.rawValue, 8)
        XCTAssertEqual(NativeDecompilerWireAuthoredScalarKind.unsigned64.rawValue, 9)
        XCTAssertEqual(NativeDecompilerWireAuthoredScalarKind.float32.rawValue, 10)
        XCTAssertEqual(NativeDecompilerWireAuthoredScalarKind.float64.rawValue, 11)

        XCTAssertEqual(NativeDecompilerWireAuthoredDarwinAliasKind.sizeT.rawValue, 0)
        XCTAssertEqual(NativeDecompilerWireAuthoredDarwinAliasKind.ssizeT.rawValue, 1)
        XCTAssertEqual(NativeDecompilerWireAuthoredDarwinAliasKind.intptrT.rawValue, 2)
        XCTAssertEqual(NativeDecompilerWireAuthoredDarwinAliasKind.uintptrT.rawValue, 3)
        XCTAssertEqual(NativeDecompilerWireAuthoredDarwinAliasKind.ptrdiffT.rawValue, 4)
        XCTAssertEqual(NativeDecompilerWireAuthoredDarwinAliasKind.wcharT.rawValue, 5)

        XCTAssertEqual(NativeDecompilerWireAuthoredNamedKind.`struct`.rawValue, 0)
        XCTAssertEqual(NativeDecompilerWireAuthoredNamedKind.union.rawValue, 1)
        XCTAssertEqual(NativeDecompilerWireAuthoredNamedKind.`enum`.rawValue, 2)
        XCTAssertEqual(NativeDecompilerWireAuthoredNamedKind.typedef.rawValue, 3)
        XCTAssertEqual(NativeDecompilerWireAuthoredTypeDefinitionKind.recordStruct.rawValue, 0)
        XCTAssertEqual(NativeDecompilerWireAuthoredTypeDefinitionKind.recordUnion.rawValue, 1)
        XCTAssertEqual(NativeDecompilerWireAuthoredTypeDefinitionKind.enumeration.rawValue, 2)
        XCTAssertEqual(NativeDecompilerWireAuthoredTypeDefinitionKind.typedef.rawValue, 3)

        XCTAssertEqual(NativeDecompilerWireAuthoredNameSubjectKind.function.rawValue, 0)
        XCTAssertEqual(NativeDecompilerWireAuthoredNameSubjectKind.label.rawValue, 1)
        XCTAssertEqual(NativeDecompilerWireAuthoredNameSubjectKind.data.rawValue, 2)
        XCTAssertEqual(NativeDecompilerWireAppliedTypeSubjectKind.memoryObject.rawValue, 0)
        XCTAssertEqual(NativeDecompilerWireAuthoredParameterListState.unspecified.rawValue, 0)
        XCTAssertEqual(NativeDecompilerWireAuthoredParameterListState.authoritative.rawValue, 1)
        XCTAssertEqual(NativeDecompilerWireAuthoredVariadicState.unspecified.rawValue, 0)
        XCTAssertEqual(NativeDecompilerWireAuthoredVariadicState.fixed.rawValue, 1)
        XCTAssertEqual(NativeDecompilerWireAuthoredVariadicState.variadic.rawValue, 2)
        XCTAssertEqual(NativeDecompilerWireAuthoredNoReturnState.unspecified.rawValue, 0)
        XCTAssertEqual(NativeDecompilerWireAuthoredNoReturnState.returns.rawValue, 1)
        XCTAssertEqual(NativeDecompilerWireAuthoredNoReturnState.noReturn.rawValue, 2)

        XCTAssertEqual(NativeDecompilerWireAuthoredFieldStorageTag.value.rawValue, 0)
        XCTAssertEqual(NativeDecompilerWireAuthoredFieldStorageTag.fixedArray.rawValue, 1)
        XCTAssertEqual(NativeDecompilerWireAuthoredFieldStorageTag.flexibleArray.rawValue, 2)
        XCTAssertEqual(NativeDecompilerWireAuthoredFieldStorageTag.opaquePointerCarrier.rawValue, 3)
        XCTAssertEqual(NativeDecompilerWireAuthoredFieldStorageTag.inlineAggregate.rawValue, 4)
        XCTAssertEqual(
            NativeDecompilerWireAuthoredOpaquePointerCarrierKind.functionPointer.rawValue,
            0
        )
        XCTAssertEqual(
            NativeDecompilerWireAuthoredOpaquePointerCarrierKind.pointerToArray.rawValue,
            1
        )
        XCTAssertEqual(NativeDecompilerWireAuthoredEnumRepresentation.signed32.rawValue, 0)
        XCTAssertEqual(NativeDecompilerWireAuthoredQualifiers.constant.rawValue, 0x01)
        XCTAssertEqual(NativeDecompilerWireAuthoredQualifiers.volatile.rawValue, 0x02)
        XCTAssertEqual(NativeDecompilerWireAuthoredQualifiers.restrict.rawValue, 0x04)

        let inputs = NativeDecompilerWireAuthoredInputs(
            schemaVersion: 1,
            names: [],
            signatures: [
                .init(
                    functionAddress: .init(0x1_0000_1000),
                    returnType: nil,
                    parameterListState: .unspecified,
                    parameters: [],
                    variadicState: .unspecified,
                    noReturnState: .noReturn
                ),
            ],
            appliedTypes: [],
            typeDefinitions: []
        )
        let object = try jsonObject(inputs)
        let signatures = try XCTUnwrap(object["signatures"] as? [[String: Any]])
        let signature = try XCTUnwrap(signatures.first)
        let noReturnValue = try XCTUnwrap(signature["noReturnState"] as? NSNumber)

        XCTAssertEqual(noReturnValue.uint8Value, 2)
        XCTAssertNotEqual(CFGetTypeID(noReturnValue), CFBooleanGetTypeID())
        XCTAssertNil(signature["isNoReturn"])
    }

    func testQualifiedValueAndDataPointerRetainEveryQualifierLevel() throws {
        let pointee = NativeDecompilerWireAuthoredType.qualifiedValue(
            atom: .named(kind: .`struct`, name: "Packet"),
            qualifiers: [.constant, .volatile]
        )
        let pointer = NativeDecompilerWireAuthoredType.dataPointer(
            pointee: pointee,
            indirectionLevel: .init(3),
            pointerQualifiersByLevel: [
                [.constant],
                [.volatile, .restrict],
                [.constant, .volatile, .restrict],
            ]
        )

        XCTAssertEqual(pointer.tag, .dataPointer)
        XCTAssertEqual(pointee.tag, .qualifiedValue)
        XCTAssertEqual(try roundTrip(pointer), pointer)

        let object = try jsonObject(pointer)
        XCTAssertEqual(Set(object.keys), ["tag", "pointee", "indirectionLevel", "pointerQualifiersByLevel"])
        XCTAssertEqual((object["tag"] as? NSNumber)?.uint8Value, 1)
        let encodedPointee = try XCTUnwrap(object["pointee"] as? [String: Any])
        XCTAssertEqual(Set(encodedPointee.keys), ["tag", "atom", "qualifiers"])
        XCTAssertEqual((encodedPointee["tag"] as? NSNumber)?.uint8Value, 0)
        XCTAssertEqual((encodedPointee["qualifiers"] as? NSNumber)?.uint8Value, 0x03)
        let levels = try XCTUnwrap(object["pointerQualifiersByLevel"] as? [NSNumber])
        XCTAssertEqual(levels.map(\.uint8Value), [0x01, 0x06, 0x07])
    }

    func testFieldStorageRetainsArrayCarrierAndInlineAggregateShapes() throws {
        let arrayOfCarrier = NativeDecompilerWireAuthoredFieldStorage.fixedArray(
            element: .opaquePointerCarrier(kind: .functionPointer),
            count: .init(4)
        )
        let flexibleValues = NativeDecompilerWireAuthoredFieldStorage.flexibleArray(
            element: .value(
                .qualifiedValue(atom: .scalar(.unsigned8), qualifiers: [])
            )
        )
        let inline = NativeDecompilerWireAuthoredFieldStorage.inlineAggregate(
            kind: .union,
            layoutRules: .init(
                isPacked: true,
                packAlignment: .init(2),
                minimumAlignment: .init(8)
            ),
            fields: [
                .init(
                    name: "callbacks",
                    storage: arrayOfCarrier,
                    bitWidth: nil,
                    minimumAlignment: nil,
                    minimumAlignmentType: nil,
                    promotesInlineFields: false
                ),
                .init(
                    name: "tail",
                    storage: flexibleValues,
                    bitWidth: .init(7),
                    minimumAlignment: .init(1),
                    minimumAlignmentType: .qualifiedValue(
                        atom: .darwinAlias(.wcharT),
                        qualifiers: .volatile
                    ),
                    promotesInlineFields: true
                ),
            ]
        )

        XCTAssertEqual(arrayOfCarrier.tag, .fixedArray)
        XCTAssertEqual(flexibleValues.tag, .flexibleArray)
        XCTAssertEqual(inline.tag, .inlineAggregate)
        XCTAssertEqual(try roundTrip(inline), inline)

        let inlineObject = try jsonObject(inline)
        XCTAssertEqual(Set(inlineObject.keys), ["tag", "kind", "layoutRules", "fields"])
        XCTAssertEqual((inlineObject["tag"] as? NSNumber)?.uint8Value, 4)
        let fields = try XCTUnwrap(inlineObject["fields"] as? [[String: Any]])
        let fixedArray = try XCTUnwrap(fields.first?["storage"] as? [String: Any])
        XCTAssertEqual(Set(fixedArray.keys), ["tag", "count", "element"])
        XCTAssertEqual((fixedArray["tag"] as? NSNumber)?.uint8Value, 1)
        let carrier = try XCTUnwrap(fixedArray["element"] as? [String: Any])
        XCTAssertEqual(Set(carrier.keys), ["tag", "kind"])
        XCTAssertEqual((carrier["tag"] as? NSNumber)?.uint8Value, 3)
    }

    func testDefinitionAndRootCollectionsUseFrozenSemanticOrder() throws {
        let valueType = NativeDecompilerWireAuthoredType.qualifiedValue(
            atom: .scalar(.signed32),
            qualifiers: []
        )
        let inputs = NativeDecompilerWireAuthoredInputs(
            schemaVersion: 1,
            names: [
                .init(address: .init(0x30), subjectKind: .data, name: "zData"),
                .init(address: .init(0x10), subjectKind: .label, name: "aLabel"),
                .init(address: .init(0x10), subjectKind: .function, name: "zFunction"),
            ],
            signatures: [
                signature(address: 0x30, noReturnState: .noReturn),
                signature(address: 0x10, noReturnState: .returns),
            ],
            appliedTypes: [
                .init(
                    address: .init(0x40), subjectKind: .memoryObject,
                    typeDefinitionName: "Zulu", byteCount: .init(8)
                ),
                .init(
                    address: .init(0x20), subjectKind: .memoryObject,
                    typeDefinitionName: "Alpha", byteCount: .init(4)
                ),
            ],
            typeDefinitions: [
                .typedef(name: "Zulu", target: .value(valueType)),
                .record(
                    kind: .`struct`,
                    name: "Alpha",
                    layoutRules: emptyLayoutRules,
                    fields: []
                ),
            ]
        )

        let fields = try canonicalFields(
            NativeDecompilerWireCanonicalRequest.canonicalAuthoredInputBytes(inputs)
        )
        XCTAssertEqual(try uint64Field("authoredInputs.names[0].address", in: fields), 0x10)
        XCTAssertEqual(try byteField("authoredInputs.names[0].subjectKind", in: fields), 0)
        XCTAssertEqual(try textField("authoredInputs.names[0].name", in: fields), "zFunction")
        XCTAssertEqual(try uint64Field("authoredInputs.names[1].address", in: fields), 0x10)
        XCTAssertEqual(try byteField("authoredInputs.names[1].subjectKind", in: fields), 1)
        XCTAssertEqual(try textField("authoredInputs.names[1].name", in: fields), "aLabel")
        XCTAssertEqual(try uint64Field("authoredInputs.names[2].address", in: fields), 0x30)

        XCTAssertEqual(try uint64Field("authoredInputs.signatures[0].functionAddress", in: fields), 0x10)
        XCTAssertEqual(try uint64Field("authoredInputs.signatures[1].functionAddress", in: fields), 0x30)
        XCTAssertEqual(try uint64Field("authoredInputs.appliedTypes[0].address", in: fields), 0x20)
        XCTAssertEqual(try uint64Field("authoredInputs.appliedTypes[1].address", in: fields), 0x40)
        XCTAssertEqual(try textField("authoredInputs.typeDefinitions[0].name", in: fields), "Alpha")
        XCTAssertEqual(try byteField("authoredInputs.typeDefinitions[0].kind", in: fields), 0)
        XCTAssertEqual(try textField("authoredInputs.typeDefinitions[1].name", in: fields), "Zulu")
        XCTAssertEqual(try byteField("authoredInputs.typeDefinitions[1].kind", in: fields), 3)

        let duplicateName = NativeDecompilerWireAuthoredInputs(
            schemaVersion: 1,
            names: inputs.names + [
                .init(address: .init(0x10), subjectKind: .function, name: "duplicate"),
            ],
            signatures: inputs.signatures,
            appliedTypes: inputs.appliedTypes,
            typeDefinitions: inputs.typeDefinitions
        )
        XCTAssertThrowsError(
            try NativeDecompilerWireCanonicalRequest.canonicalAuthoredInputBytes(duplicateName)
        )
    }

    func testUnknownQualifierBitsAndDepthSeventeenReject() throws {
        let unknownQualifiers = NativeDecompilerWireAuthoredInputs(
            schemaVersion: 1,
            names: [],
            signatures: [
                .init(
                    functionAddress: .init(0x1000),
                    returnType: .qualifiedValue(
                        atom: .scalar(.signed32),
                        qualifiers: .init(rawValue: 0x08)
                    ),
                    parameterListState: .unspecified,
                    parameters: [],
                    variadicState: .unspecified,
                    noReturnState: .unspecified
                ),
            ],
            appliedTypes: [],
            typeDefinitions: []
        )
        XCTAssertThrowsError(
            try NativeDecompilerWireCanonicalRequest.canonicalAuthoredInputBytes(unknownQualifiers)
        )

        let leaf = NativeDecompilerWireAuthoredFieldStorage.value(
            .qualifiedValue(atom: .scalar(.unsigned8), qualifiers: [])
        )
        let depthSixteen = nestedArray(depth: 16, leaf: leaf)
        let depthSeventeen = nestedArray(depth: 17, leaf: leaf)
        XCTAssertNoThrow(
            try NativeDecompilerWireCanonicalRequest.canonicalAuthoredInputBytes(
                inputsWithTypedefTarget(depthSixteen)
            )
        )
        XCTAssertThrowsError(
            try NativeDecompilerWireCanonicalRequest.canonicalAuthoredInputBytes(
                inputsWithTypedefTarget(depthSeventeen)
            )
        )
    }

    func testCanonicalAuthoredInputDomainAndFramingMatchFrozenBytes() throws {
        let empty = NativeDecompilerWireAuthoredInputs(
            schemaVersion: 1,
            names: [],
            signatures: [],
            appliedTypes: [],
            typeDefinitions: []
        )
        let expected = try XCTUnwrap(Data(base64Encoded:
            "Njpkb21haW4KNDg6Y29tLmplZmZjb29uZXkuTWFjU2NvcGUubmF0aXZlLWF1dGhvcmVkLWlucHV0LnYxCjI4OmF1dGhvcmVkSW5wdXRzLnNjaGVtYVZlcnNpb24KODoAAAAAAAAAAQoyNjphdXRob3JlZElucHV0cy5uYW1lcy5jb3VudAo4OgAAAAAAAAAACjMxOmF1dGhvcmVkSW5wdXRzLnNpZ25hdHVyZXMuY291bnQKODoAAAAAAAAAAAozMzphdXRob3JlZElucHV0cy5hcHBsaWVkVHlwZXMuY291bnQKODoAAAAAAAAAAAozNjphdXRob3JlZElucHV0cy50eXBlRGVmaW5pdGlvbnMuY291bnQKODoAAAAAAAAAAAo="
        ))

        let actual = try NativeDecompilerWireCanonicalRequest.canonicalAuthoredInputBytes(empty)
        XCTAssertEqual(actual, expected)
        XCTAssertEqual(actual.count, 290)

        let frames = try canonicalFields(actual)
        XCTAssertEqual(frames.map(\.name), [
            "domain",
            "authoredInputs.schemaVersion",
            "authoredInputs.names.count",
            "authoredInputs.signatures.count",
            "authoredInputs.appliedTypes.count",
            "authoredInputs.typeDefinitions.count",
        ])
        XCTAssertEqual(try textField("domain", in: frames),
                       "org.macscope.MacScope.native-authored-input.v1")
    }

    func testCanonicalAuthoredInputEveryLeafHasSingleFieldFrame() throws {
        let signed = NativeDecompilerWireAuthoredType.qualifiedValue(
            atom: .scalar(.signed32),
            qualifiers: [.constant]
        )
        let pointer = NativeDecompilerWireAuthoredType.dataPointer(
            pointee: .qualifiedValue(
                atom: .named(kind: .`struct`, name: "RecordA"),
                qualifiers: [.volatile]
            ),
            indirectionLevel: .init(1),
            pointerQualifiersByLevel: [[.restrict]]
        )
        let inputs = NativeDecompilerWireAuthoredInputs(
            schemaVersion: 1,
            names: [
                .init(address: .init(0x1000), subjectKind: .function, name: "start"),
            ],
            signatures: [
                .init(
                    functionAddress: .init(0x1000),
                    returnType: pointer,
                    parameterListState: .authoritative,
                    parameters: [.init(name: "value", type: signed)],
                    variadicState: .fixed,
                    noReturnState: .returns
                ),
            ],
            appliedTypes: [
                .init(
                    address: .init(0x2000), subjectKind: .memoryObject,
                    typeDefinitionName: "RecordA", byteCount: .init(16)
                ),
            ],
            typeDefinitions: [
                .record(
                    kind: .`struct`,
                    name: "RecordA",
                    layoutRules: .init(
                        isPacked: false,
                        packAlignment: nil,
                        minimumAlignment: .init(8)
                    ),
                    fields: [
                        .init(
                            name: "bits",
                            storage: .fixedArray(
                                element: .opaquePointerCarrier(kind: .pointerToArray),
                                count: .init(2)
                            ),
                            bitWidth: nil,
                            minimumAlignment: .init(8),
                            minimumAlignmentType: signed,
                            promotesInlineFields: false
                        ),
                        .init(
                            name: "",
                            storage: .value(signed),
                            bitWidth: .init(31),
                            minimumAlignment: nil,
                            minimumAlignmentType: nil,
                            promotesInlineFields: false
                        ),
                    ]
                ),
                .enumeration(
                    name: "State",
                    representation: .signed32,
                    cases: [.init(name: "negative", value: -1)]
                ),
                .typedef(
                    name: "Word",
                    target: .value(
                        .qualifiedValue(atom: .darwinAlias(.uintptrT), qualifiers: [])
                    )
                ),
            ]
        )

        let frames = try canonicalFields(
            NativeDecompilerWireCanonicalRequest.canonicalAuthoredInputBytes(inputs)
        )
        let expectedNames = expectedCompleteFixtureFieldNames
        XCTAssertEqual(frames.map(\.name), expectedNames)
        XCTAssertEqual(Set(frames.map(\.name)).count, frames.count)

        XCTAssertEqual(try byteField("authoredInputs.signatures[0].returnType.present", in: frames), 1)
        XCTAssertEqual(try byteField("authoredInputs.signatures[0].returnType.tag", in: frames), 1)
        XCTAssertEqual(
            try byteField("authoredInputs.signatures[0].returnType.pointee.atom.namedKind", in: frames),
            0
        )
        XCTAssertEqual(
            try byteField("authoredInputs.typeDefinitions[0].fields[0].storage.element.kind", in: frames),
            1
        )
        XCTAssertEqual(
            try dataField("authoredInputs.typeDefinitions[1].cases[0].value", in: frames),
            Data([0xff, 0xff, 0xff, 0xff])
        )
    }

    func testEverySwiftOwnedStructuralBoundRejectsMaximumPlusOneFirst() throws {
        let namesAtMaximum = NativeDecompilerWireAuthoredInputs(
            schemaVersion: 1,
            names: (0..<4_096).map {
                .init(address: .init(UInt64($0)), subjectKind: .function, name: "n")
            },
            signatures: [],
            appliedTypes: [],
            typeDefinitions: []
        )
        try assertStructuralMaximumAcceptedOrCanonicalByteLimited(namesAtMaximum)
        assertAuthoredError(.tooManyNames) {
            try NativeDecompilerWireCanonicalRequest.canonicalAuthoredInputBytes(
                replacing(namesAtMaximum, names: namesAtMaximum.names + [
                    .init(address: .init(4_096), subjectKind: .function, name: "n"),
                ])
            )
        }

        let signaturesAtMaximum = NativeDecompilerWireAuthoredInputs(
            schemaVersion: 1,
            names: [],
            signatures: (0..<4_096).map {
                signature(address: UInt64($0), noReturnState: .unspecified)
            },
            appliedTypes: [],
            typeDefinitions: []
        )
        try assertStructuralMaximumAcceptedOrCanonicalByteLimited(signaturesAtMaximum)
        assertAuthoredError(.tooManySignatures) {
            try NativeDecompilerWireCanonicalRequest.canonicalAuthoredInputBytes(
                replacing(signaturesAtMaximum, signatures: signaturesAtMaximum.signatures + [
                    signature(address: 4_096, noReturnState: .unspecified),
                ])
            )
        }

        let parameter = NativeDecompilerWireAuthoredParameter(
            name: "p",
            type: .qualifiedValue(atom: .scalar(.signed32), qualifiers: [])
        )
        let parametersAtMaximum = NativeDecompilerWireAuthoredInputs(
            schemaVersion: 1,
            names: [],
            signatures: [
                .init(
                    functionAddress: .init(0x1000),
                    returnType: nil,
                    parameterListState: .authoritative,
                    parameters: Array(repeating: parameter, count: 256),
                    variadicState: .fixed,
                    noReturnState: .unspecified
                ),
            ],
            appliedTypes: [],
            typeDefinitions: []
        )
        try assertStructuralMaximumAcceptedOrCanonicalByteLimited(parametersAtMaximum)
        let overParameterSignature = NativeDecompilerWireAuthoredSignature(
            functionAddress: .init(0x1000),
            returnType: nil,
            parameterListState: .authoritative,
            parameters: Array(repeating: parameter, count: 257),
            variadicState: .fixed,
            noReturnState: .unspecified
        )
        assertAuthoredError(.tooManyParameters) {
            try NativeDecompilerWireCanonicalRequest.canonicalAuthoredInputBytes(
                replacing(parametersAtMaximum, signatures: [overParameterSignature])
            )
        }

        let appliedTypesAtMaximum = NativeDecompilerWireAuthoredInputs(
            schemaVersion: 1,
            names: [],
            signatures: [],
            appliedTypes: (0..<4_096).map {
                .init(
                    address: .init(UInt64($0)),
                    subjectKind: .memoryObject,
                    typeDefinitionName: "T",
                    byteCount: .init(1)
                )
            },
            typeDefinitions: []
        )
        try assertStructuralMaximumAcceptedOrCanonicalByteLimited(appliedTypesAtMaximum)
        assertAuthoredError(.tooManyAppliedTypes) {
            try NativeDecompilerWireCanonicalRequest.canonicalAuthoredInputBytes(
                replacing(appliedTypesAtMaximum, appliedTypes: appliedTypesAtMaximum.appliedTypes + [
                    .init(
                        address: .init(4_096),
                        subjectKind: .memoryObject,
                        typeDefinitionName: "T",
                        byteCount: .init(1)
                    ),
                ])
            )
        }

        let typeDefinitionsAtMaximum = NativeDecompilerWireAuthoredInputs(
            schemaVersion: 1,
            names: [],
            signatures: [],
            appliedTypes: [],
            typeDefinitions: (0..<1_024).map {
                .typedef(
                    name: "T\($0)",
                    target: .opaquePointerCarrier(kind: .functionPointer)
                )
            }
        )
        try assertStructuralMaximumAcceptedOrCanonicalByteLimited(typeDefinitionsAtMaximum)
        assertAuthoredError(.tooManyTypeDefinitions) {
            try NativeDecompilerWireCanonicalRequest.canonicalAuthoredInputBytes(
                replacing(
                    typeDefinitionsAtMaximum,
                    typeDefinitions: typeDefinitionsAtMaximum.typeDefinitions + [
                        .typedef(
                            name: "T1024",
                            target: .opaquePointerCarrier(kind: .functionPointer)
                        ),
                    ]
                )
            )
        }
    }

    func testSharedAggregateMemberAndFixedArrayBoundsAreExact() throws {
        let valueType = NativeDecompilerWireAuthoredType.qualifiedValue(
            atom: .scalar(.unsigned8),
            qualifiers: []
        )
        let parameters = (0..<256).map {
            NativeDecompilerWireAuthoredParameter(name: "p\($0)", type: valueType)
        }
        let fields = (0..<8_064).map {
            NativeDecompilerWireAuthoredRecordField(
                name: "f\($0)",
                storage: .value(valueType),
                bitWidth: nil,
                minimumAlignment: nil,
                minimumAlignmentType: nil,
                promotesInlineFields: false
            )
        }
        let cases = (0..<8_064).map {
            NativeDecompilerWireAuthoredEnumCase(name: "c\($0)", value: Int32($0))
        }
        let aggregateAtMaximum = NativeDecompilerWireAuthoredInputs(
            schemaVersion: 1,
            names: [],
            signatures: [
                .init(
                    functionAddress: .init(0x1000),
                    returnType: nil,
                    parameterListState: .authoritative,
                    parameters: parameters,
                    variadicState: .fixed,
                    noReturnState: .unspecified
                ),
            ],
            appliedTypes: [],
            typeDefinitions: [
                .record(
                    kind: .`struct`,
                    name: "Record",
                    layoutRules: emptyLayoutRules,
                    fields: fields
                ),
                .enumeration(name: "State", representation: .signed32, cases: cases),
            ]
        )
        XCTAssertEqual(parameters.count + fields.count + cases.count, 16_384)
        try assertStructuralMaximumAcceptedOrCanonicalByteLimited(aggregateAtMaximum)

        let oneMoreCase = NativeDecompilerWireAuthoredEnumCase(name: "overflow", value: 8_064)
        assertAuthoredError(.tooManyAggregateMembers) {
            try NativeDecompilerWireCanonicalRequest.canonicalAuthoredInputBytes(
                replacing(
                    aggregateAtMaximum,
                    typeDefinitions: [
                        aggregateAtMaximum.typeDefinitions[0],
                        .enumeration(
                            name: "State",
                            representation: .signed32,
                            cases: cases + [oneMoreCase]
                        ),
                    ]
                )
            )
        }

        let maximumArray = NativeDecompilerWireAuthoredFieldStorage.fixedArray(
            element: .value(valueType),
            count: .init(1_048_576)
        )
        XCTAssertNoThrow(
            try NativeDecompilerWireCanonicalRequest.canonicalAuthoredInputBytes(
                inputsWithTypedefTarget(maximumArray)
            )
        )
        assertAuthoredError(.fixedArrayElementCountOutOfRange) {
            try NativeDecompilerWireCanonicalRequest.canonicalAuthoredInputBytes(
                inputsWithTypedefTarget(
                    .fixedArray(element: .value(valueType), count: .init(1_048_577))
                )
            )
        }

        let eightByteType = NativeDecompilerWireAuthoredType.qualifiedValue(
            atom: .scalar(.unsigned64),
            qualifiers: []
        )
        XCTAssertNoThrow(
            try NativeDecompilerWireCanonicalRequest.canonicalAuthoredInputBytes(
                inputsWithTypedefTarget(
                    .fixedArray(element: .value(eightByteType), count: .init(131_072))
                )
            )
        )
        assertAuthoredError(.computedStorageTooLarge) {
            try NativeDecompilerWireCanonicalRequest.canonicalAuthoredInputBytes(
                inputsWithTypedefTarget(
                    .fixedArray(element: .value(eightByteType), count: .init(131_073))
                )
            )
        }
    }

    func testSemanticAndCatalogTextLeafBoundsAreExactUTF8Bytes() throws {
        let semanticMaximum = String(repeating: "é", count: 512)
        XCTAssertEqual(semanticMaximum.utf8.count, 1_024)
        let semanticAtMaximum = NativeDecompilerWireAuthoredInputs(
            schemaVersion: 1,
            names: [
                .init(address: .init(0x1000), subjectKind: .function, name: semanticMaximum),
            ],
            signatures: [],
            appliedTypes: [],
            typeDefinitions: []
        )
        XCTAssertNoThrow(
            try NativeDecompilerWireCanonicalRequest.canonicalAuthoredInputBytes(semanticAtMaximum)
        )
        assertAuthoredError(.semanticNameTooLong) {
            try NativeDecompilerWireCanonicalRequest.canonicalAuthoredInputBytes(
                replacing(
                    semanticAtMaximum,
                    names: [
                        .init(
                            address: .init(0x1000),
                            subjectKind: .function,
                            name: semanticMaximum + "n"
                        ),
                    ]
                )
            )
        }

        let catalogMaximum = String(repeating: "é", count: 2_048)
        XCTAssertEqual(catalogMaximum.utf8.count, 4_096)
        let catalogType = NativeDecompilerWireAuthoredType.qualifiedValue(
            atom: .named(kind: .typedef, name: catalogMaximum),
            qualifiers: []
        )
        let catalogAtMaximum = NativeDecompilerWireAuthoredInputs(
            schemaVersion: 1,
            names: [],
            signatures: [
                .init(
                    functionAddress: .init(0x1000),
                    returnType: catalogType,
                    parameterListState: .unspecified,
                    parameters: [],
                    variadicState: .unspecified,
                    noReturnState: .unspecified
                ),
            ],
            appliedTypes: [],
            typeDefinitions: []
        )
        XCTAssertNoThrow(
            try NativeDecompilerWireCanonicalRequest.canonicalAuthoredInputBytes(catalogAtMaximum)
        )
        assertAuthoredError(.catalogTextTooLong) {
            let overlong = NativeDecompilerWireAuthoredType.qualifiedValue(
                atom: .named(kind: .typedef, name: catalogMaximum + "T"),
                qualifiers: []
            )
            try NativeDecompilerWireCanonicalRequest.canonicalAuthoredInputBytes(
                replacing(
                    catalogAtMaximum,
                    signatures: [
                        .init(
                            functionAddress: .init(0x1000),
                            returnType: overlong,
                            parameterListState: .unspecified,
                            parameters: [],
                            variadicState: .unspecified,
                            noReturnState: .unspecified
                        ),
                    ]
                )
            )
        }
    }

    func testCanonicalAuthoredByteCeilingAcceptsExactLimitAndRejectsPlusOne() throws {
        let exactLengths = try nameLengthsForCanonicalByteCount(1_048_576)
        XCTAssertEqual(expectedNamesOnlyCanonicalByteCount(exactLengths), 1_048_576)

        let exact = namesOnlyInputs(nameLengths: exactLengths)
        let exactBytes = try NativeDecompilerWireCanonicalRequest.canonicalAuthoredInputBytes(exact)
        XCTAssertEqual(exactBytes.count, 1_048_576)

        var plusOneLengths = exactLengths
        let adjustableIndex = try XCTUnwrap(plusOneLengths.firstIndex {
            $0 < 1_024 && canonicalTokenByteCount($0 + 1) == canonicalTokenByteCount($0) + 1
        })
        plusOneLengths[adjustableIndex] += 1
        XCTAssertEqual(expectedNamesOnlyCanonicalByteCount(plusOneLengths), 1_048_577)
        assertAuthoredError(.canonicalAuthoredInputTooLarge) {
            try NativeDecompilerWireCanonicalRequest.canonicalAuthoredInputBytes(
                namesOnlyInputs(nameLengths: plusOneLengths)
            )
        }
    }

    func testClosedCodableRejectsLegacySynthesizedUnknownAndMismatchedShapes() throws {
        let scalarAtom: [String: Any] = ["tag": 1, "scalarKind": 6]
        let qualified: [String: Any] = ["tag": 0, "atom": scalarAtom, "qualifiers": 0]
        let signature: [String: Any] = [
            "functionAddress": "0000000000001000",
            "parameterListState": 0,
            "parameters": [],
            "variadicState": 0,
            "noReturnState": 0,
        ]

        var legacyBoolean = signature
        legacyBoolean["isNoReturn"] = true
        try assertPropertyListRejects(
            NativeDecompilerWireAuthoredSignature.self,
            object: legacyBoolean
        )

        try assertPropertyListRejects(
            NativeDecompilerWireAuthoredType.self,
            object: ["qualifiedValue": ["atom": scalarAtom, "qualifiers": 0]]
        )
        try assertPropertyListRejects(
            NativeDecompilerWireAuthoredType.self,
            object: ["tag": 2, "atom": scalarAtom, "qualifiers": 0]
        )
        try assertPropertyListRejects(
            NativeDecompilerWireAuthoredNoReturnState.self,
            object: 3
        )
        try assertPropertyListRejects(
            NativeDecompilerWireAuthoredType.self,
            object: ["tag": 0, "atom": scalarAtom, "qualifiers": 8]
        )

        try assertPropertyListRejects(
            NativeDecompilerWireAuthoredType.self,
            object: ["tag": 0, "atom": scalarAtom]
        )
        var extraKey = qualified
        extraKey["unexpected"] = 1
        try assertPropertyListRejects(
            NativeDecompilerWireAuthoredType.self,
            object: extraKey
        )

        try assertPropertyListRejects(
            NativeDecompilerWireAuthoredType.self,
            object: [
                "tag": 0,
                "pointee": qualified,
                "indirectionLevel": "0000000000000001",
                "pointerQualifiersByLevel": [0],
            ]
        )
        try assertPropertyListRejects(
            NativeDecompilerWireAuthoredType.self,
            object: ["tag": 1, "atom": scalarAtom, "qualifiers": 0]
        )
    }

    func testAllOrderedChildrenAndSemanticDuplicateClassesAreFrozen() throws {
        let firstType = NativeDecompilerWireAuthoredType.qualifiedValue(
            atom: .scalar(.signed16),
            qualifiers: []
        )
        let secondType = NativeDecompilerWireAuthoredType.qualifiedValue(
            atom: .scalar(.unsigned64),
            qualifiers: []
        )
        let inlineStorage = NativeDecompilerWireAuthoredFieldStorage.inlineAggregate(
            kind: .`struct`,
            layoutRules: emptyLayoutRules,
            fields: [
                recordField(name: "inlineSecond", storage: .value(secondType)),
                recordField(name: "inlineFirst", storage: .value(firstType)),
            ]
        )
        let inputs = NativeDecompilerWireAuthoredInputs(
            schemaVersion: 1,
            names: [],
            signatures: [
                .init(
                    functionAddress: .init(0x1000),
                    returnType: nil,
                    parameterListState: .authoritative,
                    parameters: [
                        .init(name: "second", type: secondType),
                        .init(name: "first", type: firstType),
                    ],
                    variadicState: .fixed,
                    noReturnState: .returns
                ),
            ],
            appliedTypes: [
                .init(
                    address: .init(0x2000),
                    subjectKind: .memoryObject,
                    typeDefinitionName: "Record",
                    byteCount: .init(16)
                ),
            ],
            typeDefinitions: [
                .record(
                    kind: .`struct`,
                    name: "Record",
                    layoutRules: emptyLayoutRules,
                    fields: [
                        recordField(name: "outerSecond", storage: inlineStorage),
                        recordField(name: "outerFirst", storage: .value(firstType)),
                    ]
                ),
                .enumeration(
                    name: "State",
                    representation: .signed32,
                    cases: [
                        .init(name: "secondCase", value: 2),
                        .init(name: "firstCase", value: 1),
                    ]
                ),
            ]
        )
        let fields = try canonicalFields(
            NativeDecompilerWireCanonicalRequest.canonicalAuthoredInputBytes(inputs)
        )
        XCTAssertEqual(try textField("authoredInputs.signatures[0].parameters[0].name", in: fields), "second")
        XCTAssertEqual(try textField("authoredInputs.signatures[0].parameters[1].name", in: fields), "first")
        XCTAssertEqual(try textField("authoredInputs.typeDefinitions[0].fields[0].name", in: fields), "outerSecond")
        XCTAssertEqual(try textField("authoredInputs.typeDefinitions[0].fields[1].name", in: fields), "outerFirst")
        XCTAssertEqual(
            try textField(
                "authoredInputs.typeDefinitions[0].fields[0].storage.fields[0].name",
                in: fields
            ),
            "inlineSecond"
        )
        XCTAssertEqual(
            try textField(
                "authoredInputs.typeDefinitions[0].fields[0].storage.fields[1].name",
                in: fields
            ),
            "inlineFirst"
        )
        XCTAssertEqual(try textField("authoredInputs.typeDefinitions[1].cases[0].name", in: fields), "secondCase")
        XCTAssertEqual(try textField("authoredInputs.typeDefinitions[1].cases[1].name", in: fields), "firstCase")

        assertAuthoredError(.duplicateSignature) {
            try NativeDecompilerWireCanonicalRequest.canonicalAuthoredInputBytes(
                replacing(inputs, signatures: inputs.signatures + [inputs.signatures[0]])
            )
        }
        assertAuthoredError(.duplicateAppliedType) {
            try NativeDecompilerWireCanonicalRequest.canonicalAuthoredInputBytes(
                replacing(inputs, appliedTypes: inputs.appliedTypes + [
                    .init(
                        address: .init(0x2000),
                        subjectKind: .memoryObject,
                        typeDefinitionName: "Other",
                        byteCount: .init(8)
                    ),
                ])
            )
        }
        assertAuthoredError(.duplicateTypeDefinition) {
            try NativeDecompilerWireCanonicalRequest.canonicalAuthoredInputBytes(
                replacing(inputs, typeDefinitions: inputs.typeDefinitions + [
                    .typedef(name: "Record", target: .value(firstType)),
                ])
            )
        }
    }

    func testRecursiveFlexibleArrayAndInlineAggregateEveryLeafHasSingleFieldFrame() throws {
        let elementType = NativeDecompilerWireAuthoredType.qualifiedValue(
            atom: .scalar(.unsigned8),
            qualifiers: [.constant]
        )
        let target = NativeDecompilerWireAuthoredFieldStorage.inlineAggregate(
            kind: .`struct`,
            layoutRules: .init(
                isPacked: true,
                packAlignment: .init(1),
                minimumAlignment: nil
            ),
            fields: [
                recordField(
                    name: "tail",
                    storage: .flexibleArray(element: .value(elementType)),
                    promotesInlineFields: false
                ),
            ]
        )
        let frames = try canonicalFields(
            NativeDecompilerWireCanonicalRequest.canonicalAuthoredInputBytes(
                NativeDecompilerWireAuthoredInputs(
                    schemaVersion: 1,
                    names: [],
                    signatures: [],
                    appliedTypes: [],
                    typeDefinitions: [
                        .record(
                            kind: .`struct`,
                            name: "RecursiveStorage",
                            layoutRules: emptyLayoutRules,
                            fields: [recordField(name: "payload", storage: target)]
                        ),
                    ]
                )
            )
        )
        XCTAssertEqual(frames.map(\.name), expectedRecursiveStorageFieldNames)
        XCTAssertEqual(Set(frames.map(\.name)).count, frames.count)
        XCTAssertEqual(
            try byteField(
                "authoredInputs.typeDefinitions[0].fields[0].storage.tag",
                in: frames
            ),
            NativeDecompilerWireAuthoredFieldStorageTag.inlineAggregate.rawValue
        )
        XCTAssertEqual(
            try byteField(
                "authoredInputs.typeDefinitions[0].fields[0].storage.fields[0].storage.tag",
                in: frames
            ),
            NativeDecompilerWireAuthoredFieldStorageTag.flexibleArray.rawValue
        )
    }

    func testFlexibleArrayRejectsHiddenDescendantsBehindFixedArrayUnionAndNonfinalStructField() throws {
        let byteType = NativeDecompilerWireAuthoredType.qualifiedValue(
            atom: .scalar(.unsigned8),
            qualifiers: []
        )
        let flexibleTail = NativeDecompilerWireAuthoredFieldStorage.flexibleArray(
            element: .value(byteType)
        )
        let inlineStructWithFlexibleTail = NativeDecompilerWireAuthoredFieldStorage.inlineAggregate(
            kind: .`struct`,
            layoutRules: emptyLayoutRules,
            fields: [recordField(name: "tail", storage: flexibleTail)]
        )
        let definitions: [NativeDecompilerWireAuthoredTypeDefinition] = [
            .record(
                kind: .`struct`,
                name: "FixedArrayBarrier",
                layoutRules: emptyLayoutRules,
                fields: [
                    recordField(
                        name: "items",
                        storage: .fixedArray(
                            element: inlineStructWithFlexibleTail,
                            count: .init(1)
                        )
                    ),
                ]
            ),
            .record(
                kind: .union,
                name: "UnionBarrier",
                layoutRules: emptyLayoutRules,
                fields: [
                    recordField(name: "member", storage: inlineStructWithFlexibleTail),
                ]
            ),
            .record(
                kind: .`struct`,
                name: "NonfinalBarrier",
                layoutRules: emptyLayoutRules,
                fields: [
                    recordField(name: "hidden", storage: inlineStructWithFlexibleTail),
                    recordField(name: "sentinel", storage: .value(byteType)),
                ]
            ),
        ]

        for definition in definitions {
            let inputs = NativeDecompilerWireAuthoredInputs(
                schemaVersion: 1,
                names: [],
                signatures: [],
                appliedTypes: [],
                typeDefinitions: [definition]
            )
            assertTypedAuthoredRejection(
                "Flexible-array descendants must not cross an array, union, or nonfinal-field barrier."
            ) {
                try NativeDecompilerWireCanonicalRequest.canonicalAuthoredInputBytes(inputs)
            }
        }
    }

    func testFlexibleArrayAcceptsDirectAndDescendantFinalStructPlacement() throws {
        let byteType = NativeDecompilerWireAuthoredType.qualifiedValue(
            atom: .scalar(.unsigned8),
            qualifiers: []
        )
        let flexibleTail = NativeDecompilerWireAuthoredFieldStorage.flexibleArray(
            element: .value(byteType)
        )
        let direct = NativeDecompilerWireAuthoredTypeDefinition.record(
            kind: .`struct`,
            name: "DirectFlexibleTail",
            layoutRules: emptyLayoutRules,
            fields: [recordField(name: "tail", storage: flexibleTail)]
        )
        let descendant = NativeDecompilerWireAuthoredTypeDefinition.record(
            kind: .`struct`,
            name: "DescendantFlexibleTail",
            layoutRules: emptyLayoutRules,
            fields: [
                recordField(
                    name: "payload",
                    storage: .inlineAggregate(
                        kind: .`struct`,
                        layoutRules: emptyLayoutRules,
                        fields: [
                            recordField(name: "header", storage: .value(byteType)),
                            recordField(name: "tail", storage: flexibleTail),
                        ]
                    )
                ),
            ]
        )

        for definition in [direct, descendant] {
            let inputs = NativeDecompilerWireAuthoredInputs(
                schemaVersion: 1,
                names: [],
                signatures: [],
                appliedTypes: [],
                typeDefinitions: [definition]
            )
            XCTAssertNoThrow(
                try NativeDecompilerWireCanonicalRequest.canonicalAuthoredInputBytes(inputs)
            )
        }
    }

    func testUnspecifiedParameterListCannotCarryParameters() throws {
        let contradictory = NativeDecompilerWireAuthoredInputs(
            schemaVersion: 1,
            names: [],
            signatures: [
                .init(
                    functionAddress: .init(0x1000),
                    returnType: nil,
                    parameterListState: .unspecified,
                    parameters: [
                        .init(
                            name: "hidden",
                            type: .qualifiedValue(atom: .scalar(.signed32), qualifiers: [])
                        ),
                    ],
                    variadicState: .unspecified,
                    noReturnState: .unspecified
                ),
            ],
            appliedTypes: [],
            typeDefinitions: []
        )
        assertTypedAuthoredRejection {
            try NativeDecompilerWireCanonicalRequest.canonicalAuthoredInputBytes(contradictory)
        }
    }

    func testClosedCodableRejectsSemanticallyInvalidDataPointers() throws {
        let scalarAtom: [String: Any] = ["tag": 1, "scalarKind": 6]
        let qualified: [String: Any] = ["tag": 0, "atom": scalarAtom, "qualifiers": 0]
        let validPointer: [String: Any] = [
            "tag": 1,
            "pointee": qualified,
            "indirectionLevel": "0000000000000001",
            "pointerQualifiersByLevel": [0],
        ]

        try assertPropertyListRejects(
            NativeDecompilerWireAuthoredType.self,
            object: [
                "tag": 1,
                "pointee": validPointer,
                "indirectionLevel": "0000000000000001",
                "pointerQualifiersByLevel": [0],
            ]
        )
        try assertPropertyListRejects(
            NativeDecompilerWireAuthoredType.self,
            object: [
                "tag": 1,
                "pointee": qualified,
                "indirectionLevel": "0000000000000000",
                "pointerQualifiersByLevel": [],
            ]
        )
        try assertPropertyListRejects(
            NativeDecompilerWireAuthoredType.self,
            object: [
                "tag": 1,
                "pointee": qualified,
                "indirectionLevel": "0000000000000009",
                "pointerQualifiersByLevel": Array(repeating: 0, count: 9),
            ]
        )
        try assertPropertyListRejects(
            NativeDecompilerWireAuthoredType.self,
            object: [
                "tag": 1,
                "pointee": qualified,
                "indirectionLevel": "0000000000000002",
                "pointerQualifiersByLevel": [0],
            ]
        )
    }

    func testClosedCodableRejectsInlineAggregateEnumAndTypedefKinds() throws {
        for invalidKind in [
            NativeDecompilerWireAuthoredNamedKind.`enum`.rawValue,
            NativeDecompilerWireAuthoredNamedKind.typedef.rawValue,
        ] {
            try assertPropertyListRejects(
                NativeDecompilerWireAuthoredFieldStorage.self,
                object: [
                    "tag": NativeDecompilerWireAuthoredFieldStorageTag.inlineAggregate.rawValue,
                    "kind": invalidKind,
                    "layoutRules": ["isPacked": false],
                    "fields": [],
                ]
            )
        }
    }

    func testRecordFieldAnonymousAndPromotionShapesAreClosed() throws {
        let scalar = NativeDecompilerWireAuthoredType.qualifiedValue(
            atom: .scalar(.unsigned32),
            qualifiers: []
        )
        let unnamedZeroWidth = NativeDecompilerWireAuthoredRecordField(
            name: "",
            storage: .value(scalar),
            bitWidth: .init(0),
            minimumAlignment: nil,
            minimumAlignmentType: nil,
            promotesInlineFields: false
        )
        let unnamedPositiveWidth = NativeDecompilerWireAuthoredRecordField(
            name: "",
            storage: .value(scalar),
            bitWidth: .init(3),
            minimumAlignment: nil,
            minimumAlignmentType: nil,
            promotesInlineFields: false
        )
        let anonymousPromotedInline = NativeDecompilerWireAuthoredRecordField(
            name: "",
            storage: .inlineAggregate(
                kind: .`struct`,
                layoutRules: emptyLayoutRules,
                fields: [recordField(name: "member", storage: .value(scalar))]
            ),
            bitWidth: nil,
            minimumAlignment: nil,
            minimumAlignmentType: nil,
            promotesInlineFields: true
        )

        for field in [unnamedZeroWidth, unnamedPositiveWidth, anonymousPromotedInline] {
            XCTAssertEqual(try roundTrip(field), field)
            XCTAssertNoThrow(
                try NativeDecompilerWireCanonicalRequest.canonicalAuthoredInputBytes(
                    inputsWithRecordField(field)
                )
            )
        }

        let namedZeroWidth = NativeDecompilerWireAuthoredRecordField(
            name: "named",
            storage: .value(scalar),
            bitWidth: .init(0),
            minimumAlignment: nil,
            minimumAlignmentType: nil,
            promotesInlineFields: false
        )
        let emptyOrdinary = NativeDecompilerWireAuthoredRecordField(
            name: "",
            storage: .value(scalar),
            bitWidth: nil,
            minimumAlignment: nil,
            minimumAlignmentType: nil,
            promotesInlineFields: false
        )
        let namedPromotedInline = NativeDecompilerWireAuthoredRecordField(
            name: "named",
            storage: .inlineAggregate(
                kind: .union,
                layoutRules: emptyLayoutRules,
                fields: [recordField(name: "member", storage: .value(scalar))]
            ),
            bitWidth: nil,
            minimumAlignment: nil,
            minimumAlignmentType: nil,
            promotesInlineFields: true
        )
        let promotedNonInline = NativeDecompilerWireAuthoredRecordField(
            name: "named",
            storage: .value(scalar),
            bitWidth: nil,
            minimumAlignment: nil,
            minimumAlignmentType: nil,
            promotesInlineFields: true
        )

        for field in [namedZeroWidth, emptyOrdinary, namedPromotedInline, promotedNonInline] {
            assertTypedAuthoredRejection {
                try NativeDecompilerWireCanonicalRequest.canonicalAuthoredInputBytes(
                    inputsWithRecordField(field)
                )
            }
        }
    }
}

private extension NativeDecompilerWireAuthoredModelsTests {
    struct CanonicalField: Equatable {
        let name: String
        let value: Data
    }

    enum CanonicalFixtureError: Error {
        case malformedFrame
        case missingField(String)
        case duplicateField(String)
        case wrongWidth(String)
        case invalidText(String)
        case cannotConstructBoundary(Int)
    }

    var emptyLayoutRules: NativeDecompilerWireAuthoredLayoutRules {
        .init(isPacked: false, packAlignment: nil, minimumAlignment: nil)
    }

    func signature(
        address: UInt64,
        noReturnState: NativeDecompilerWireAuthoredNoReturnState
    ) -> NativeDecompilerWireAuthoredSignature {
        .init(
            functionAddress: .init(address),
            returnType: nil,
            parameterListState: .unspecified,
            parameters: [],
            variadicState: .unspecified,
            noReturnState: noReturnState
        )
    }

    func inputsWithTypedefTarget(
        _ target: NativeDecompilerWireAuthoredFieldStorage
    ) -> NativeDecompilerWireAuthoredInputs {
        .init(
            schemaVersion: 1,
            names: [],
            signatures: [],
            appliedTypes: [],
            typeDefinitions: [.typedef(name: "Nested", target: target)]
        )
    }

    func inputsWithRecordField(
        _ field: NativeDecompilerWireAuthoredRecordField
    ) -> NativeDecompilerWireAuthoredInputs {
        .init(
            schemaVersion: 1,
            names: [],
            signatures: [],
            appliedTypes: [],
            typeDefinitions: [
                .record(
                    kind: .`struct`,
                    name: "FieldShape",
                    layoutRules: emptyLayoutRules,
                    fields: [field]
                ),
            ]
        )
    }

    func nestedArray(
        depth: Int,
        leaf: NativeDecompilerWireAuthoredFieldStorage
    ) -> NativeDecompilerWireAuthoredFieldStorage {
        (0..<depth).reduce(leaf) { storage, _ in
            .fixedArray(element: storage, count: .init(1))
        }
    }

    func recordField(
        name: String,
        storage: NativeDecompilerWireAuthoredFieldStorage,
        promotesInlineFields: Bool = false
    ) -> NativeDecompilerWireAuthoredRecordField {
        .init(
            name: name,
            storage: storage,
            bitWidth: nil,
            minimumAlignment: nil,
            minimumAlignmentType: nil,
            promotesInlineFields: promotesInlineFields
        )
    }

    func replacing(
        _ inputs: NativeDecompilerWireAuthoredInputs,
        names: [NativeDecompilerWireAuthoredName]? = nil,
        signatures: [NativeDecompilerWireAuthoredSignature]? = nil,
        appliedTypes: [NativeDecompilerWireAppliedType]? = nil,
        typeDefinitions: [NativeDecompilerWireAuthoredTypeDefinition]? = nil
    ) -> NativeDecompilerWireAuthoredInputs {
        .init(
            schemaVersion: inputs.schemaVersion,
            names: names ?? inputs.names,
            signatures: signatures ?? inputs.signatures,
            appliedTypes: appliedTypes ?? inputs.appliedTypes,
            typeDefinitions: typeDefinitions ?? inputs.typeDefinitions
        )
    }

    func assertAuthoredError<T>(
        _ expected: NativeDecompilerWireAuthoredValidationError,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ operation: () throws -> T
    ) {
        XCTAssertThrowsError(try operation(), file: file, line: line) { error in
            XCTAssertEqual(
                error as? NativeDecompilerWireAuthoredValidationError,
                expected,
                file: file,
                line: line
            )
        }
    }

    func assertTypedAuthoredRejection<T>(
        _ message: String = "Expected a typed authored-input rejection.",
        file: StaticString = #filePath,
        line: UInt = #line,
        _ operation: () throws -> T
    ) {
        XCTAssertThrowsError(try operation(), message, file: file, line: line) { error in
            XCTAssertNotNil(
                error as? NativeDecompilerWireAuthoredValidationError,
                "Expected NativeDecompilerWireAuthoredValidationError, received \(error).",
                file: file,
                line: line
            )
        }
    }

    func assertStructuralMaximumAcceptedOrCanonicalByteLimited(
        _ inputs: NativeDecompilerWireAuthoredInputs,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        do {
            _ = try NativeDecompilerWireCanonicalRequest.canonicalAuthoredInputBytes(inputs)
        } catch let error as NativeDecompilerWireAuthoredValidationError {
            XCTAssertEqual(
                error,
                .canonicalAuthoredInputTooLarge,
                "A structural maximum may reach only the independent aggregate byte ceiling.",
                file: file,
                line: line
            )
            if error != .canonicalAuthoredInputTooLarge {
                throw error
            }
        }
    }

    func assertPropertyListRejects<T: Decodable>(
        _ type: T.Type,
        object: Any,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let data = try PropertyListSerialization.data(
            fromPropertyList: object,
            format: .binary,
            options: 0
        )
        XCTAssertThrowsError(
            try PropertyListDecoder().decode(type, from: data),
            file: file,
            line: line
        )
    }

    func canonicalTokenByteCount(_ payloadByteCount: Int) -> Int {
        String(payloadByteCount).utf8.count + 1 + payloadByteCount + 1
    }

    func canonicalFieldByteCount(_ name: String, valueByteCount: Int) -> Int {
        canonicalTokenByteCount(name.utf8.count) + canonicalTokenByteCount(valueByteCount)
    }

    func expectedNamesOnlyCanonicalByteCount(_ nameLengths: [Int]) -> Int {
        var count = canonicalFieldByteCount(
            "domain",
            valueByteCount: "org.macscope.MacScope.native-authored-input.v1".utf8.count
        )
        count += canonicalFieldByteCount("authoredInputs.schemaVersion", valueByteCount: 8)
        count += canonicalFieldByteCount("authoredInputs.names.count", valueByteCount: 8)
        for (index, nameLength) in nameLengths.enumerated() {
            let prefix = "authoredInputs.names[\(index)]"
            count += canonicalFieldByteCount("\(prefix).address", valueByteCount: 8)
            count += canonicalFieldByteCount("\(prefix).subjectKind", valueByteCount: 1)
            count += canonicalFieldByteCount("\(prefix).name", valueByteCount: nameLength)
        }
        count += canonicalFieldByteCount("authoredInputs.signatures.count", valueByteCount: 8)
        count += canonicalFieldByteCount("authoredInputs.appliedTypes.count", valueByteCount: 8)
        count += canonicalFieldByteCount("authoredInputs.typeDefinitions.count", valueByteCount: 8)
        return count
    }

    func namesOnlyInputs(nameLengths: [Int]) -> NativeDecompilerWireAuthoredInputs {
        .init(
            schemaVersion: 1,
            names: nameLengths.enumerated().map { index, length in
                .init(
                    address: .init(UInt64(index)),
                    subjectKind: .function,
                    name: String(repeating: "n", count: length)
                )
            },
            signatures: [],
            appliedTypes: [],
            typeDefinitions: []
        )
    }

    func nameLengthsForCanonicalByteCount(_ target: Int) throws -> [Int] {
        let minimumLength = 1
        let maximumLength = 1_024
        let minimumToken = canonicalTokenByteCount(minimumLength)
        let maximumToken = canonicalTokenByteCount(maximumLength)
        let maximumDelta = maximumToken - minimumToken
        let deltaToLength = Dictionary(uniqueKeysWithValues: (minimumLength...maximumLength).map {
            (canonicalTokenByteCount($0) - minimumToken, $0)
        })

        for nameCount in 2...4_096 {
            let zeroValueSize = expectedNamesOnlyCanonicalByteCount(
                Array(repeating: 0, count: nameCount)
            )
            let fixedSize = zeroValueSize - nameCount * canonicalTokenByteCount(0)
            let requiredValueTokens = target - fixedSize
            let minimumValueTokens = nameCount * minimumToken
            let maximumValueTokens = nameCount * maximumToken
            guard requiredValueTokens >= minimumValueTokens,
                  requiredValueTokens <= maximumValueTokens
            else { continue }

            var lengths = Array(repeating: minimumLength, count: nameCount)
            var remainingDelta = requiredValueTokens - minimumValueTokens
            let maximumFilled = min(nameCount - 2, remainingDelta / maximumDelta)
            if maximumFilled > 0 {
                for index in 0..<maximumFilled {
                    lengths[index] = maximumLength
                }
                remainingDelta -= maximumFilled * maximumDelta
            }

            var foundPair: (Int, Int)?
            for firstLength in minimumLength...maximumLength {
                let firstDelta = canonicalTokenByteCount(firstLength) - minimumToken
                guard firstDelta <= remainingDelta else { break }
                if let secondLength = deltaToLength[remainingDelta - firstDelta] {
                    foundPair = (firstLength, secondLength)
                    break
                }
            }
            guard let foundPair else { continue }
            lengths[maximumFilled] = foundPair.0
            lengths[maximumFilled + 1] = foundPair.1

            guard expectedNamesOnlyCanonicalByteCount(lengths) == target,
                  lengths.contains(where: {
                      $0 < maximumLength
                          && canonicalTokenByteCount($0 + 1) == canonicalTokenByteCount($0) + 1
                  })
            else { continue }
            return lengths
        }
        throw CanonicalFixtureError.cannotConstructBoundary(target)
    }

    func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let encoded = try encoder.encode(value)
        return try PropertyListDecoder().decode(T.self, from: encoded)
    }

    func jsonObject<T: Encodable>(_ value: T) throws -> [String: Any] {
        let encoded = try JSONEncoder().encode(value)
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded, options: []) as? [String: Any]
        )
    }

    func canonicalFields(_ data: Data) throws -> [CanonicalField] {
        let bytes = Array(data)
        var offset = 0

        func token() throws -> Data {
            let lengthStart = offset
            while offset < bytes.count, bytes[offset] >= 0x30, bytes[offset] <= 0x39 {
                offset += 1
            }
            guard offset > lengthStart, offset < bytes.count, bytes[offset] == 0x3a else {
                throw CanonicalFixtureError.malformedFrame
            }
            guard let length = Int(String(decoding: bytes[lengthStart..<offset], as: UTF8.self)) else {
                throw CanonicalFixtureError.malformedFrame
            }
            offset += 1
            let valueStart = offset
            let (valueEnd, overflow) = valueStart.addingReportingOverflow(length)
            guard !overflow, valueEnd < bytes.count, bytes[valueEnd] == 0x0a else {
                throw CanonicalFixtureError.malformedFrame
            }
            offset = valueEnd + 1
            return Data(bytes[valueStart..<valueEnd])
        }

        var result: [CanonicalField] = []
        while offset < bytes.count {
            let nameData = try token()
            guard let name = String(data: nameData, encoding: .utf8) else {
                throw CanonicalFixtureError.malformedFrame
            }
            result.append(.init(name: name, value: try token()))
        }
        return result
    }

    func dataField(_ name: String, in fields: [CanonicalField]) throws -> Data {
        let matches = fields.filter { $0.name == name }
        guard !matches.isEmpty else { throw CanonicalFixtureError.missingField(name) }
        guard matches.count == 1 else { throw CanonicalFixtureError.duplicateField(name) }
        return matches[0].value
    }

    func byteField(_ name: String, in fields: [CanonicalField]) throws -> UInt8 {
        let value = try dataField(name, in: fields)
        guard value.count == 1, let byte = value.first else {
            throw CanonicalFixtureError.wrongWidth(name)
        }
        return byte
    }

    func uint64Field(_ name: String, in fields: [CanonicalField]) throws -> UInt64 {
        let value = try dataField(name, in: fields)
        guard value.count == 8 else { throw CanonicalFixtureError.wrongWidth(name) }
        return value.reduce(0) { ($0 << 8) | UInt64($1) }
    }

    func textField(_ name: String, in fields: [CanonicalField]) throws -> String {
        let value = try dataField(name, in: fields)
        guard let text = String(data: value, encoding: .utf8) else {
            throw CanonicalFixtureError.invalidText(name)
        }
        return text
    }

    var expectedCompleteFixtureFieldNames: [String] {
        [
            "domain",
            "authoredInputs.schemaVersion",
            "authoredInputs.names.count",
            "authoredInputs.names[0].address",
            "authoredInputs.names[0].subjectKind",
            "authoredInputs.names[0].name",
            "authoredInputs.signatures.count",
            "authoredInputs.signatures[0].functionAddress",
            "authoredInputs.signatures[0].returnType.present",
            "authoredInputs.signatures[0].returnType.tag",
            "authoredInputs.signatures[0].returnType.depth",
            "authoredInputs.signatures[0].returnType.pointee.tag",
            "authoredInputs.signatures[0].returnType.pointee.depth",
            "authoredInputs.signatures[0].returnType.pointee.atom.tag",
            "authoredInputs.signatures[0].returnType.pointee.atom.namedKind",
            "authoredInputs.signatures[0].returnType.pointee.atom.name",
            "authoredInputs.signatures[0].returnType.pointee.qualifiers",
            "authoredInputs.signatures[0].returnType.indirectionLevel",
            "authoredInputs.signatures[0].returnType.pointerQualifiers.count",
            "authoredInputs.signatures[0].returnType.pointerQualifiers[0]",
            "authoredInputs.signatures[0].parameterListState",
            "authoredInputs.signatures[0].parameters.count",
            "authoredInputs.signatures[0].parameters[0].name",
            "authoredInputs.signatures[0].parameters[0].type.tag",
            "authoredInputs.signatures[0].parameters[0].type.depth",
            "authoredInputs.signatures[0].parameters[0].type.atom.tag",
            "authoredInputs.signatures[0].parameters[0].type.atom.scalarKind",
            "authoredInputs.signatures[0].parameters[0].type.qualifiers",
            "authoredInputs.signatures[0].variadicState",
            "authoredInputs.signatures[0].noReturnState",
            "authoredInputs.appliedTypes.count",
            "authoredInputs.appliedTypes[0].address",
            "authoredInputs.appliedTypes[0].subjectKind",
            "authoredInputs.appliedTypes[0].typeDefinitionName",
            "authoredInputs.appliedTypes[0].byteCount",
            "authoredInputs.typeDefinitions.count",
            "authoredInputs.typeDefinitions[0].kind",
            "authoredInputs.typeDefinitions[0].name",
            "authoredInputs.typeDefinitions[0].layoutRules.isPacked",
            "authoredInputs.typeDefinitions[0].layoutRules.packAlignment.present",
            "authoredInputs.typeDefinitions[0].layoutRules.minimumAlignment.present",
            "authoredInputs.typeDefinitions[0].layoutRules.minimumAlignment.value",
            "authoredInputs.typeDefinitions[0].fields.count",
            "authoredInputs.typeDefinitions[0].fields[0].name",
            "authoredInputs.typeDefinitions[0].fields[0].storage.tag",
            "authoredInputs.typeDefinitions[0].fields[0].storage.depth",
            "authoredInputs.typeDefinitions[0].fields[0].storage.count",
            "authoredInputs.typeDefinitions[0].fields[0].storage.element.tag",
            "authoredInputs.typeDefinitions[0].fields[0].storage.element.depth",
            "authoredInputs.typeDefinitions[0].fields[0].storage.element.kind",
            "authoredInputs.typeDefinitions[0].fields[0].bitWidth.present",
            "authoredInputs.typeDefinitions[0].fields[0].minimumAlignment.present",
            "authoredInputs.typeDefinitions[0].fields[0].minimumAlignment.value",
            "authoredInputs.typeDefinitions[0].fields[0].minimumAlignmentType.present",
            "authoredInputs.typeDefinitions[0].fields[0].minimumAlignmentType.tag",
            "authoredInputs.typeDefinitions[0].fields[0].minimumAlignmentType.depth",
            "authoredInputs.typeDefinitions[0].fields[0].minimumAlignmentType.atom.tag",
            "authoredInputs.typeDefinitions[0].fields[0].minimumAlignmentType.atom.scalarKind",
            "authoredInputs.typeDefinitions[0].fields[0].minimumAlignmentType.qualifiers",
            "authoredInputs.typeDefinitions[0].fields[0].promotesInlineFields",
            "authoredInputs.typeDefinitions[0].fields[1].name",
            "authoredInputs.typeDefinitions[0].fields[1].storage.tag",
            "authoredInputs.typeDefinitions[0].fields[1].storage.depth",
            "authoredInputs.typeDefinitions[0].fields[1].storage.type.tag",
            "authoredInputs.typeDefinitions[0].fields[1].storage.type.depth",
            "authoredInputs.typeDefinitions[0].fields[1].storage.type.atom.tag",
            "authoredInputs.typeDefinitions[0].fields[1].storage.type.atom.scalarKind",
            "authoredInputs.typeDefinitions[0].fields[1].storage.type.qualifiers",
            "authoredInputs.typeDefinitions[0].fields[1].bitWidth.present",
            "authoredInputs.typeDefinitions[0].fields[1].bitWidth.value",
            "authoredInputs.typeDefinitions[0].fields[1].minimumAlignment.present",
            "authoredInputs.typeDefinitions[0].fields[1].minimumAlignmentType.present",
            "authoredInputs.typeDefinitions[0].fields[1].promotesInlineFields",
            "authoredInputs.typeDefinitions[1].kind",
            "authoredInputs.typeDefinitions[1].name",
            "authoredInputs.typeDefinitions[1].representation",
            "authoredInputs.typeDefinitions[1].cases.count",
            "authoredInputs.typeDefinitions[1].cases[0].name",
            "authoredInputs.typeDefinitions[1].cases[0].value",
            "authoredInputs.typeDefinitions[2].kind",
            "authoredInputs.typeDefinitions[2].name",
            "authoredInputs.typeDefinitions[2].target.tag",
            "authoredInputs.typeDefinitions[2].target.depth",
            "authoredInputs.typeDefinitions[2].target.type.tag",
            "authoredInputs.typeDefinitions[2].target.type.depth",
            "authoredInputs.typeDefinitions[2].target.type.atom.tag",
            "authoredInputs.typeDefinitions[2].target.type.atom.darwinAliasKind",
            "authoredInputs.typeDefinitions[2].target.type.qualifiers",
        ]
    }

    var expectedRecursiveStorageFieldNames: [String] {
        [
            "domain",
            "authoredInputs.schemaVersion",
            "authoredInputs.names.count",
            "authoredInputs.signatures.count",
            "authoredInputs.appliedTypes.count",
            "authoredInputs.typeDefinitions.count",
            "authoredInputs.typeDefinitions[0].kind",
            "authoredInputs.typeDefinitions[0].name",
            "authoredInputs.typeDefinitions[0].layoutRules.isPacked",
            "authoredInputs.typeDefinitions[0].layoutRules.packAlignment.present",
            "authoredInputs.typeDefinitions[0].layoutRules.minimumAlignment.present",
            "authoredInputs.typeDefinitions[0].fields.count",
            "authoredInputs.typeDefinitions[0].fields[0].name",
            "authoredInputs.typeDefinitions[0].fields[0].storage.tag",
            "authoredInputs.typeDefinitions[0].fields[0].storage.depth",
            "authoredInputs.typeDefinitions[0].fields[0].storage.kind",
            "authoredInputs.typeDefinitions[0].fields[0].storage.layoutRules.isPacked",
            "authoredInputs.typeDefinitions[0].fields[0].storage.layoutRules.packAlignment.present",
            "authoredInputs.typeDefinitions[0].fields[0].storage.layoutRules.packAlignment.value",
            "authoredInputs.typeDefinitions[0].fields[0].storage.layoutRules.minimumAlignment.present",
            "authoredInputs.typeDefinitions[0].fields[0].storage.fields.count",
            "authoredInputs.typeDefinitions[0].fields[0].storage.fields[0].name",
            "authoredInputs.typeDefinitions[0].fields[0].storage.fields[0].storage.tag",
            "authoredInputs.typeDefinitions[0].fields[0].storage.fields[0].storage.depth",
            "authoredInputs.typeDefinitions[0].fields[0].storage.fields[0].storage.element.tag",
            "authoredInputs.typeDefinitions[0].fields[0].storage.fields[0].storage.element.depth",
            "authoredInputs.typeDefinitions[0].fields[0].storage.fields[0].storage.element.type.tag",
            "authoredInputs.typeDefinitions[0].fields[0].storage.fields[0].storage.element.type.depth",
            "authoredInputs.typeDefinitions[0].fields[0].storage.fields[0].storage.element.type.atom.tag",
            "authoredInputs.typeDefinitions[0].fields[0].storage.fields[0].storage.element.type.atom.scalarKind",
            "authoredInputs.typeDefinitions[0].fields[0].storage.fields[0].storage.element.type.qualifiers",
            "authoredInputs.typeDefinitions[0].fields[0].storage.fields[0].bitWidth.present",
            "authoredInputs.typeDefinitions[0].fields[0].storage.fields[0].minimumAlignment.present",
            "authoredInputs.typeDefinitions[0].fields[0].storage.fields[0].minimumAlignmentType.present",
            "authoredInputs.typeDefinitions[0].fields[0].storage.fields[0].promotesInlineFields",
            "authoredInputs.typeDefinitions[0].fields[0].bitWidth.present",
            "authoredInputs.typeDefinitions[0].fields[0].minimumAlignment.present",
            "authoredInputs.typeDefinitions[0].fields[0].minimumAlignmentType.present",
            "authoredInputs.typeDefinitions[0].fields[0].promotesInlineFields",
        ]
    }
}

import CryptoKit
import Foundation
import XCTest
@testable import MacScope

final class NativeDecompilerAuthoredInputProjectorTests: XCTestCase {
    func testProjectsOnlyRequestedImageNamesWithExactSubjectKinds() throws {
        let snapshot = try A4aFixture.snapshot(
            selectedOverrides: [
                A4aFixture.selectedFunctionStart: .init(customName: "chosen_function"),
                A4aFixture.selectedFunctionStart + 4: .init(customName: "chosen_label"),
                A4aFixture.readableDataStart: .init(customName: "chosen_data"),
            ],
            siblingOverrides: [
                A4aFixture.siblingFunctionStart: .init(customName: "sibling_function"),
            ],
            selectedInstructions: [
                A4aFixture.instruction(address: A4aFixture.selectedFunctionStart),
                A4aFixture.instruction(address: A4aFixture.selectedFunctionStart + 4),
            ]
        )

        let projection = try requireValid(snapshot)
        XCTAssertEqual(projection.authoredInputs.names, [
            .init(
                address: .init(A4aFixture.selectedFunctionStart),
                subjectKind: .function,
                name: "chosen_function"
            ),
            .init(
                address: .init(A4aFixture.selectedFunctionStart + 4),
                subjectKind: .label,
                name: "chosen_label"
            ),
            .init(
                address: .init(A4aFixture.readableDataStart),
                subjectKind: .data,
                name: "chosen_data"
            ),
        ])
        XCTAssertFalse(projection.authoredInputs.names.contains { $0.name == "sibling_function" })
    }

    func testSelectedCustomFunctionNameProjectsOneFunctionRecordWithoutDerivedCompetitor() throws {
        let symbols = [
            A4aFixture.symbol(id: 1, name: "_derived_one", address: A4aFixture.selectedFunctionStart),
            A4aFixture.symbol(id: 2, name: "_derived_two", address: A4aFixture.selectedFunctionStart),
        ]
        let snapshot = try A4aFixture.snapshot(
            selectedOverrides: [
                A4aFixture.selectedFunctionStart: .init(customName: "authored_name"),
            ],
            selectedSymbols: symbols
        )

        let names = try requireValid(snapshot).authoredInputs.names
        XCTAssertEqual(names, [
            .init(
                address: .init(A4aFixture.selectedFunctionStart),
                subjectKind: .function,
                name: "authored_name"
            ),
        ])
        XCTAssertFalse(names.contains { $0.name.hasPrefix("_derived") })
    }

    func testDoesNotInventFunctionForNonstartOverride() throws {
        let address = A4aFixture.selectedFunctionStart + 4
        let snapshot = try A4aFixture.snapshot(
            selectedOverrides: [address: .init(customName: "inside_function")],
            selectedInstructions: [A4aFixture.instruction(address: address)]
        )

        let names = try requireValid(snapshot).authoredInputs.names
        XCTAssertEqual(names, [
            .init(address: .init(address), subjectKind: .label, name: "inside_function"),
        ])
        XCTAssertFalse(names.contains { $0.subjectKind == .function })
    }

    func testProjectsOnlyAnalysisEffectiveSignaturesAtExactFunctionStarts() throws {
        let functions = A4aFixture.functions(count: 2)
        let active = FunctionSignatureOverride(returnType: "uint32_t")
        let inert = FunctionSignatureOverride()
        let offStart = A4aFixture.selectedFunctionStart + 4
        let snapshot = try A4aFixture.snapshot(
            selectedOverrides: [
                functions[0].startAddress: .init(signature: active),
                functions[1].startAddress: .init(signature: inert),
                offStart: .init(signature: active),
            ],
            selectedFunctions: functions
        )

        let signatures = try requireValid(snapshot).authoredInputs.signatures
        XCTAssertEqual(signatures.count, 1)
        XCTAssertEqual(signatures[0].functionAddress.value, functions[0].startAddress)
        XCTAssertEqual(
            signatures[0].returnType,
            .qualifiedValue(atom: .scalar(.unsigned32), qualifiers: [])
        )
    }

    func testSignaturePreservesAbsentReturnParameterPresenceVariadicAndNoReturnAxes() throws {
        let functions = A4aFixture.functions(count: 5)
        let parameters = [
            ArgOverride(rowToken: "row-b", name: "second", type: "uint64_t", provenance: .script),
            ArgOverride(rowToken: "row-a", name: "first", type: "uint8_t", provenance: .user),
        ]
        let overrides: [UInt64: AddressOverride] = [
            functions[0].startAddress: .init(
                signature: .init(returnType: "uint32_t")
            ),
            functions[1].startAddress: .init(
                signature: .init(parameterList: .authoritative([]), variadicState: .fixed)
            ),
            functions[2].startAddress: .init(
                signature: .init(parameterList: .authoritative(parameters), variadicState: .fixed)
            ),
            functions[3].startAddress: .init(
                signature: .init(variadicState: .variadic)
            ),
            functions[4].startAddress: .init(
                signature: .init(noReturnState: .noReturn)
            ),
        ]
        let signatures = try requireValid(
            A4aFixture.snapshot(selectedOverrides: overrides, selectedFunctions: functions)
        ).authoredInputs.signatures

        XCTAssertEqual(signatures.count, 5)
        XCTAssertNotNil(signatures[0].returnType)
        XCTAssertEqual(signatures[0].parameterListState, .unspecified)
        XCTAssertEqual(signatures[0].parameters, [])
        XCTAssertEqual(signatures[0].variadicState, .unspecified)
        XCTAssertEqual(signatures[0].noReturnState, .unspecified)

        XCTAssertNil(signatures[1].returnType)
        XCTAssertEqual(signatures[1].parameterListState, .authoritative)
        XCTAssertEqual(signatures[1].parameters, [])
        XCTAssertEqual(signatures[1].variadicState, .fixed)

        XCTAssertEqual(signatures[2].parameters.map(\.name), ["second", "first"])
        XCTAssertEqual(signatures[2].parameters.map(\.type), [
            .qualifiedValue(atom: .scalar(.unsigned64), qualifiers: []),
            .qualifiedValue(atom: .scalar(.unsigned8), qualifiers: []),
        ])
        XCTAssertEqual(signatures[3].parameterListState, .unspecified)
        XCTAssertEqual(signatures[3].variadicState, .variadic)
        XCTAssertEqual(signatures[4].noReturnState, .noReturn)
    }

    func testNoReturnOnlySetAndClearProduceDistinctValidIdentity() throws {
        let setSnapshot = try A4aFixture.snapshot(selectedOverrides: [
            A4aFixture.selectedFunctionStart: .init(
                signature: .init(noReturnState: .noReturn)
            ),
        ])
        let clearSnapshot = try A4aFixture.snapshot(selectedOverrides: [
            A4aFixture.selectedFunctionStart: .init(
                signature: .init(noReturnState: .returns)
            ),
        ])

        let set = try requireValid(setSnapshot)
        let clear = try requireValid(clearSnapshot)
        XCTAssertEqual(set.authoredInputs.signatures.single?.noReturnState, .noReturn)
        XCTAssertEqual(clear.authoredInputs.signatures.single?.noReturnState, .returns)
        XCTAssertNotEqual(set.canonicalIdentitySHA256, clear.canonicalIdentitySHA256)
    }

    func testSiblingImageSameVAAndPresentationOnlyChangesAreInvariant() throws {
        let semantic = AddressOverride(customName: "selected_authority")
        let baseline = try A4aFixture.snapshot(selectedOverrides: [
            A4aFixture.selectedFunctionStart: semantic,
        ])
        var changed = try A4aFixture.snapshot(
            selectedOverrides: [
                A4aFixture.selectedFunctionStart: .init(
                    customName: "selected_authority",
                    customComment: "presentation only",
                    tag: "reviewed",
                    registerNames: ["x0": "display_only"],
                    localLabel: "local_only"
                ),
            ],
            siblingOverrides: [
                A4aFixture.siblingFunctionStart: .init(customName: "sibling_change"),
            ]
        )
        changed.binaries[0].path = "/a/different/presentation/path"
        changed.binaries[0].name = "renamed-display-binary"

        let first = try requireValid(baseline)
        let second = try requireValid(changed)
        XCTAssertEqual(first.authoredInputs, second.authoredInputs)
        XCTAssertEqual(first.canonicalIdentitySHA256, second.canonicalIdentitySHA256)
        XCTAssertEqual(first.canonicalByteCount, second.canonicalByteCount)
    }

    func testProjectsCompleteCatalogSortedByExactUTF8NameThenKind() throws {
        let definitions = [
            A4aFixture.definition("zeta", fields: [A4aFixture.field("z", "uint8_t")], id: 4),
            A4aFixture.definition("_under", kind: .union, fields: [A4aFixture.field("u", "uint64_t")], id: 2),
            A4aFixture.definition("beta", kind: .typedef, fields: [A4aFixture.field("beta", "uint16_t")], id: 3),
            A4aFixture.definition("Alpha", kind: .enum, fields: [A4aFixture.enumCase("first", 7)], id: 1),
        ]

        let projected = try requireValid(
            A4aFixture.snapshotAdmittingCatalog(typeDefinitions: definitions)
        ).authoredInputs.typeDefinitions
        XCTAssertEqual(projected.map(\.name), ["Alpha", "_under", "beta", "zeta"])
        XCTAssertEqual(projected.map(\.kind), [.enumeration, .recordUnion, .typedef, .recordStruct])
        XCTAssertEqual(projected.count, definitions.count)
    }

    func testSelectedScalarSignatureAdmitsWithoutUnrelatedUnsupportedCatalog() throws {
        var unrelated = A4aFixture.definition(
            "Unrelated",
            kind: .typedef,
            fields: [A4aFixture.field("Unrelated", "uint8_t")],
            id: 101
        )
        unrelated.vectorByteSize = 16
        let selected: [UInt64: AddressOverride] = [
            A4aFixture.selectedFunctionStart: .init(signature: .init(returnType: "uint32_t")),
        ]
        let baseline = try requireValid(A4aFixture.snapshot(selectedOverrides: selected))
        let withUnrelated = try requireValid(A4aFixture.snapshot(
            selectedOverrides: selected, typeDefinitions: [unrelated]
        ))
        XCTAssertEqual(withUnrelated.authoredInputs, baseline.authoredInputs)
        XCTAssertEqual(withUnrelated.canonicalIdentitySHA256, baseline.canonicalIdentitySHA256)
    }

    /// DP04 D2: a stack local typed as an accepted struct pointer carries that struct's
    /// definition, and the local-name projection sends the typed local to native.
    func testStackLocalStructTypeReachesNativeThroughAuthoredInputs() throws {
        let accepted = TypeDefinition(kind: .struct, name: "UseObject", fields: [
            FieldDef(name: "_unknown_0x0", type: "uint8_t[8]"), FieldDef(name: "field_0x8", type: "uint64_t"),
        ], layoutRules: AggregateLayoutRules(isPacked: true))
        let stackLocals = ["-24:-16": StackLocalOverride(typeName: "UseObject *")]
        let snapshot = try A4aFixture.snapshot(
            selectedOverrides: [A4aFixture.selectedFunctionStart: .init(stackLocals: stackLocals)],
            typeDefinitions: [accepted]
        )
        let inputs = try requireValid(snapshot).authoredInputs
        XCTAssertTrue(inputs.typeDefinitions.contains {
            if case let .record(_, name, _, _) = $0 { return name == "UseObject" } else { return false }
        }, "the referenced definition is carried")
        let localRows = [("sub", "sp, sp, #32"), ("str", "x0, [sp, #8]"),
                         ("add", "sp, sp, #32"), ("ret", "")].enumerated().map { index, pair in
            InstructionRow(address: A4aFixture.selectedFunctionStart + UInt64(index * 4), bytes: "",
                           mnemonic: pair.0, operands: pair.1, hasBreakpoint: false, comment: nil)
        }
        let liveStorage = MacIRBuilder().buildFunction(name: "locals", startAddress: A4aFixture.selectedFunctionStart,
                                                       instructions: localRows).localVariables.compactMap(\.stackStorage)
        let withLocals = NativeDecompilerSnapshotBuilder.withAuthoredLocalNames(
            inputs, stackLocals: stackLocals, registerNames: [:], liveStackStorage: liveStorage,
            catalogDefinitions: snapshot.typeDefinitions)
        let local = try XCTUnwrap(withLocals.localNames.first)
        XCTAssertEqual(local.stackOffset, -24)
        XCTAssertEqual(local.name, "local_18", "a type-only edit keeps Ghidra's default name")
        guard case let .dataPointer(pointee, _, _)? = local.type,
              case let .qualifiedValue(atom, _) = pointee, case let .named(_, name) = atom else {
            return XCTFail("expected UseObject *, got \(String(describing: local.type))")
        }
        XCTAssertEqual(name, "UseObject")
        XCTAssertNoThrow(try NativeDecompilerWireCanonicalRequest.canonicalAuthoredInputBytes(withLocals))
    }

    func testReferencedUnsupportedDefinitionStillRejectsSelectedSignature() throws {
        var relevant = A4aFixture.definition(
            "Relevant",
            kind: .typedef,
            fields: [A4aFixture.field("Relevant", "uint8_t")],
            id: 102
        )
        relevant.vectorByteSize = 16
        assertInvalid(
            project(try A4aFixture.snapshot(
                selectedOverrides: [
                    A4aFixture.selectedFunctionStart: .init(
                        signature: .init(returnType: "Relevant")
                    ),
                ],
                typeDefinitions: [relevant]
            )),
            category: .unsupported,
            code: "authoring-input-unsupported",
            subject: "type-catalog"
        )
    }

    func testAppliedTypeRootUsesExactUTF8KeyAndDoesNotAdmitOtherSpelling() throws {
        let composed = A4aFixture.definition("\u{00E9}", fields: [A4aFixture.field("v", "uint8_t")], id: 103)
        let decomposed = A4aFixture.definition("e\u{0301}", fields: [FieldDef(name: "legacy", type: "void *")], id: 104)
        let projection = try requireValid(A4aFixture.snapshot(
            selectedOverrides: [A4aFixture.readableDataStart: .init(appliedTypeName: "\u{00E9}")],
            typeDefinitions: [decomposed, composed]
        ))
        XCTAssertEqual(projection.authoredInputs.typeDefinitions.map(\.name), ["\u{00E9}"])
        XCTAssertEqual(projection.authoredInputs.appliedTypes.single?.typeDefinitionName, "\u{00E9}")
    }

    func testProjectsRecordEnumAndTypedefKindSpecificPayloads() throws {
        let record = A4aFixture.definition(
            "Packet",
            fields: [
                A4aFixture.field("tag", "uint8_t"),
                A4aFixture.field("words", "uint16_t[2]"),
            ],
            layout: .init(isPacked: true, packAlignment: 4, minimumAlignment: 8),
            id: 1
        )
        let enumeration = A4aFixture.definition(
            "Mode",
            kind: .enum,
            fields: [A4aFixture.enumCase("negative", -1), A4aFixture.enumCase("ready", 2)],
            id: 2
        )
        let typedef = A4aFixture.definition(
            "Word",
            kind: .typedef,
            fields: [A4aFixture.field("Word", "uint64_t")],
            id: 3
        )

        let definitions = try requireValid(
            A4aFixture.snapshotAdmittingCatalog(typeDefinitions: [typedef, record, enumeration])
        ).authoredInputs.typeDefinitions
        XCTAssertEqual(definitions.count, 3)

        guard case let .enumeration(enumName, representation, cases) = definitions[0] else {
            return XCTFail("Mode must project as an enumeration")
        }
        XCTAssertEqual(enumName, "Mode")
        XCTAssertEqual(representation, .signed32)
        XCTAssertEqual(cases, [.init(name: "negative", value: -1), .init(name: "ready", value: 2)])

        guard case let .record(kind, recordName, rules, fields) = definitions[1] else {
            return XCTFail("Packet must project as a record")
        }
        XCTAssertEqual(kind, .`struct`)
        XCTAssertEqual(recordName, "Packet")
        XCTAssertEqual(
            rules,
            .init(isPacked: true, packAlignment: .init(4), minimumAlignment: .init(8))
        )
        XCTAssertEqual(fields.map(\.name), ["tag", "words"])
        XCTAssertEqual(
            fields[1].storage,
            .fixedArray(
                element: .value(.qualifiedValue(atom: .scalar(.unsigned16), qualifiers: [])),
                count: .init(2)
            )
        )

        guard case let .typedef(typeName, target) = definitions[2] else {
            return XCTFail("Word must project as a typedef")
        }
        XCTAssertEqual(typeName, "Word")
        XCTAssertEqual(
            target,
            .value(.qualifiedValue(atom: .scalar(.unsigned64), qualifiers: []))
        )
    }

    func testTypedefCarrierTargetsProjectAllClosedProvenanceShapes() throws {
        let callback = A4aFixture.definition(
            "Callback",
            kind: .typedef,
            fields: [
                A4aFixture.field(
                    "Callback",
                    "int32_t *",
                    semantics: .functionPointerCarrier
                ),
            ],
            id: 101
        )
        let buffer = A4aFixture.definition(
            "Buffer",
            kind: .typedef,
            fields: [
                A4aFixture.field(
                    "Buffer",
                    "int32_t *",
                    semantics: .pointerToArrayCarrier
                ),
            ],
            id: 102
        )
        let callbacks = A4aFixture.definition(
            "Callbacks",
            kind: .typedef,
            fields: [
                A4aFixture.field(
                    "Callbacks",
                    "int32_t *[2][3]",
                    semantics: .arrayOfFunctionPointerCarrier
                ),
            ],
            id: 103
        )

        let projected = try requireValid(
            try A4aFixture.snapshotAdmittingCatalog(typeDefinitions: [callbacks, buffer, callback])
        ).authoredInputs.typeDefinitions
        XCTAssertEqual(projected.map(\.name), ["Buffer", "Callback", "Callbacks"])
        guard case let .typedef(_, bufferTarget) = projected[0],
              case let .typedef(_, callbackTarget) = projected[1],
              case let .typedef(_, callbacksTarget) = projected[2] else {
            return XCTFail("all carrier definitions must remain typedef payloads")
        }
        XCTAssertEqual(bufferTarget, .opaquePointerCarrier(kind: .pointerToArray))
        XCTAssertEqual(callbackTarget, .opaquePointerCarrier(kind: .functionPointer))
        XCTAssertEqual(
            callbacksTarget,
            .fixedArray(
                element: .fixedArray(
                    element: .opaquePointerCarrier(kind: .functionPointer),
                    count: .init(3)
                ),
                count: .init(2)
            )
        )
    }

    func testTypedefInlineStructAndUnionTargetsProjectExactClosedStorage() throws {
        let inlineStruct = A4aFixture.definition(
            "InlineStructAlias",
            kind: .typedef,
            fields: [
                A4aFixture.field(
                    "InlineStructAlias",
                    "ignored-inline-struct",
                    inlineKind: .struct,
                    inlineFields: [
                        A4aFixture.field("tag", "uint8_t"),
                        A4aFixture.field("value", "uint32_t"),
                    ],
                    inlineLayout: .init(
                        isPacked: true,
                        packAlignment: 2,
                        minimumAlignment: 8
                    )
                ),
            ],
            id: 104
        )
        let inlineUnion = A4aFixture.definition(
            "InlineUnionAlias",
            kind: .typedef,
            fields: [
                A4aFixture.field(
                    "InlineUnionAlias",
                    "ignored-inline-union",
                    inlineKind: .union,
                    inlineFields: [
                        A4aFixture.field("small", "uint8_t"),
                        A4aFixture.field("wide", "uint32_t"),
                    ],
                    inlineLayout: .init(packAlignment: 2)
                ),
            ],
            id: 105
        )

        let definitions = try requireValid(
            try A4aFixture.snapshotAdmittingCatalog(typeDefinitions: [inlineUnion, inlineStruct])
        ).authoredInputs.typeDefinitions
        XCTAssertEqual(definitions.map(\.name), ["InlineStructAlias", "InlineUnionAlias"])

        guard case let .typedef(_, structTarget) = definitions[0],
              case let .inlineAggregate(structKind, structRules, structFields) = structTarget,
              case let .typedef(_, unionTarget) = definitions[1],
              case let .inlineAggregate(unionKind, unionRules, unionFields) = unionTarget else {
            return XCTFail("typedef inline aggregates must remain exact structured storage")
        }
        XCTAssertEqual(structKind, .struct)
        XCTAssertEqual(
            structRules,
            .init(
                isPacked: true,
                packAlignment: .init(2),
                minimumAlignment: .init(8)
            )
        )
        XCTAssertEqual(structFields.map(\.name), ["tag", "value"])
        XCTAssertEqual(structFields.map(\.storage), [
            .value(.qualifiedValue(atom: .scalar(.unsigned8), qualifiers: [])),
            .value(.qualifiedValue(atom: .scalar(.unsigned32), qualifiers: [])),
        ])
        XCTAssertEqual(unionKind, .union)
        XCTAssertEqual(
            unionRules,
            .init(isPacked: false, packAlignment: .init(2), minimumAlignment: nil)
        )
        XCTAssertEqual(unionFields.map(\.name), ["small", "wide"])
        XCTAssertEqual(unionFields.map(\.storage), [
            .value(.qualifiedValue(atom: .scalar(.unsigned8), qualifiers: [])),
            .value(.qualifiedValue(atom: .scalar(.unsigned32), qualifiers: [])),
        ])
        XCTAssertEqual(
            try appliedByteCount(of: "InlineStructAlias", definitions: [inlineStruct]),
            8
        )
        XCTAssertEqual(
            try appliedByteCount(of: "InlineUnionAlias", definitions: [inlineUnion]),
            4
        )

        for (index, malformedKind) in [TypeKind.enum, .typedef].enumerated() {
            let malformed = A4aFixture.definition(
                "MalformedInlineAlias\(index)",
                kind: .typedef,
                fields: [
                    A4aFixture.field(
                        "MalformedInlineAlias\(index)",
                        "ignored-malformed-inline",
                        inlineKind: malformedKind,
                        inlineFields: [A4aFixture.field("value", "uint8_t")]
                    ),
                ],
                id: 106 + index
            )
            assertInvalid(
                project(try A4aFixture.snapshotAdmittingCatalog(typeDefinitions: [malformed])),
                category: .invalid,
                code: "authored-field-storage",
                subject: "record-field"
            )
        }
    }

    func testRejectsEnumOutsideSignedInt32AndMalformedTypedefShapes() throws {
        let overflow = A4aFixture.definition(
            "Overflow",
            kind: .enum,
            fields: [A4aFixture.field("tooLarge", "2147483648")],
            id: 1
        )
        assertInvalid(
            project(try A4aFixture.snapshotAdmittingCatalog(typeDefinitions: [overflow])),
            category: .unsupported,
            code: "authoring-input-unsupported",
            subject: "type-catalog"
        )

        for (index, fields) in [
            [],
            [A4aFixture.field("one", "uint8_t"), A4aFixture.field("two", "uint16_t")],
        ].enumerated() {
            let malformed = A4aFixture.definition(
                "BadTypedef\(index)",
                kind: .typedef,
                fields: fields,
                id: index + 2
            )
            assertInvalid(
                project(try A4aFixture.snapshotAdmittingCatalog(typeDefinitions: [malformed])),
                category: .unsupported,
                code: "authoring-input-unsupported",
                subject: "type-catalog"
            )
        }

        let metadata = A4aFixture.definition(
            "BitTypedef",
            kind: .typedef,
            fields: [A4aFixture.field("BitTypedef", "uint32_t", bitWidth: 1)],
            id: 4
        )
        assertInvalid(
            project(try A4aFixture.snapshotAdmittingCatalog(typeDefinitions: [metadata])),
            category: .unsupported,
            code: "authoring-input-unsupported",
            subject: "type-catalog"
        )
    }

    func testRejectsDuplicateCatalogNamesAndActiveByValueCyclesButAllowsPointerCycles() throws {
        let duplicateA = A4aFixture.definition("Collision", fields: [], id: 1)
        let duplicateB = A4aFixture.definition("Collision", kind: .union, fields: [], id: 2)
        assertInvalid(
            project(try A4aFixture.snapshotAdmittingCatalog(typeDefinitions: [duplicateA, duplicateB])),
            category: .invalid,
            code: "authored-catalog-definition",
            subject: "type-catalog"
        )

        let byValueA = A4aFixture.definition(
            "ValueA",
            fields: [A4aFixture.field("b", "ValueB")],
            id: 3
        )
        let byValueB = A4aFixture.definition(
            "ValueB",
            fields: [A4aFixture.field("a", "ValueA")],
            id: 4
        )
        assertInvalid(
            project(try A4aFixture.snapshotAdmittingCatalog(typeDefinitions: [byValueA, byValueB])),
            category: .unsupported,
            code: "authoring-input-unsupported",
            subject: "type-layout"
        )

        let pointerNode = A4aFixture.definition(
            "Node",
            fields: [A4aFixture.field("next", "Node *")],
            id: 5
        )
        let pointerSnapshot = try A4aFixture.snapshot(
            selectedOverrides: [
                A4aFixture.readableDataStart: .init(appliedTypeName: "Node"),
            ],
            typeDefinitions: [pointerNode]
        )
        XCTAssertEqual(
            try requireValid(pointerSnapshot).authoredInputs.appliedTypes.single?.byteCount.value,
            8
        )
    }

    func testAppliedMemoryObjectRequiresExactReadableNoncodeExtent() throws {
        let scalar = A4aFixture.definition(
            "Scalar",
            fields: [A4aFixture.field("value", "uint64_t")],
            id: 1
        )
        let valid = try A4aFixture.snapshot(
            selectedOverrides: [
                A4aFixture.readableDataStart: .init(appliedTypeName: "Scalar"),
            ],
            typeDefinitions: [scalar]
        )
        XCTAssertEqual(try requireValid(valid).authoredInputs.appliedTypes, [
            .init(
                address: .init(A4aFixture.readableDataStart),
                subjectKind: .memoryObject,
                typeDefinitionName: "Scalar",
                byteCount: .init(8)
            ),
        ])

        let unreadableSegments = A4aFixture.defaultSegments.map { record in
            record.name == "__DATA"
                ? A4aFixture.segment(
                    "__DATA",
                    vmStart: record.preferredVMStart,
                    vmSize: record.preferredVMSize,
                    fileOffset: record.sliceRelativeFileOffset,
                    fileSize: record.fileSize,
                    protections: 0
                )
                : record
        }
        let unreadable = try A4aFixture.snapshot(
            selectedOverrides: [
                A4aFixture.readableDataStart: .init(appliedTypeName: "Scalar"),
            ],
            preferredSegments: unreadableSegments,
            typeDefinitions: [scalar]
        )
        assertInvalid(
            project(unreadable),
            category: .invalid,
            code: "authoring-input-invalid",
            subject: "applied-type"
        )

        let duplicateReadable = try A4aFixture.snapshot(
            selectedOverrides: [
                A4aFixture.readableDataStart: .init(appliedTypeName: "Scalar"),
            ],
            preferredSegments: A4aFixture.defaultSegments + [
                A4aFixture.segment(
                    "__EXTRA",
                    vmStart: A4aFixture.readableDataStart,
                    vmSize: 0x100,
                    fileOffset: 0,
                    fileSize: 0,
                    protections: 1
                ),
            ],
            typeDefinitions: [scalar]
        )
        assertInvalid(
            project(duplicateReadable),
            category: .invalid,
            code: "authoring-input-invalid",
            subject: "applied-type"
        )
    }

    func testRejectsAppliedTypeOverlapWithFunctionOrInstructionCode() throws {
        let scalar = A4aFixture.definition(
            "Scalar",
            fields: [A4aFixture.field("value", "uint64_t")],
            id: 1
        )
        let functionOverlap = try A4aFixture.snapshot(
            selectedOverrides: [
                A4aFixture.selectedFunctionStart: .init(appliedTypeName: "Scalar"),
            ],
            typeDefinitions: [scalar]
        )
        assertInvalid(
            project(functionOverlap),
            category: .invalid,
            code: "authoring-input-invalid",
            subject: "applied-type"
        )

        let codeAddress = A4aFixture.selectedFunctionStart + 0x100
        let instructionOverlap = try A4aFixture.snapshot(
            selectedOverrides: [codeAddress: .init(appliedTypeName: "Scalar")],
            selectedInstructions: [A4aFixture.instruction(address: codeAddress)],
            typeDefinitions: [scalar]
        )
        assertInvalid(
            project(instructionOverlap),
            category: .invalid,
            code: "authoring-input-invalid",
            subject: "applied-type"
        )

        let explicitlyData = try A4aFixture.snapshot(
            selectedOverrides: [
                codeAddress: .init(isData: true, appliedTypeName: "Scalar"),
            ],
            selectedInstructions: [A4aFixture.instruction(address: codeAddress)],
            typeDefinitions: [scalar]
        )
        XCTAssertEqual(
            try requireValid(explicitlyData).authoredInputs.appliedTypes.single?.byteCount.value,
            8
        )
    }

    func testDanglingAppliedTypeAbstainsButUnsafeExtantTypeInvalidatesWholeCut() throws {
        let dangling = try A4aFixture.snapshot(selectedOverrides: [
            A4aFixture.readableDataStart: .init(appliedTypeName: "Missing"),
        ])
        XCTAssertEqual(try requireValid(dangling).authoredInputs.appliedTypes, [])

        let scalar = A4aFixture.definition(
            "Extant",
            fields: [A4aFixture.field("value", "uint64_t")],
            id: 1
        )
        let unsafe = try A4aFixture.snapshot(
            selectedOverrides: [
                A4aFixture.selectedFunctionStart: .init(appliedTypeName: "Extant"),
            ],
            typeDefinitions: [scalar]
        )
        assertInvalid(
            project(unsafe),
            category: .invalid,
            code: "authoring-input-invalid",
            subject: "applied-type"
        )
    }

    func testEnforcesEveryCountDepthTextLayoutAndCanonicalByteBoundAtLimitAndLimitPlusOne() throws {
        try assertCollectionAndTextBounds()
        try assertDepthAndAggregateBounds()
        try assertCanonicalByteBoundary()
    }

    func testOneUnsupportedActiveRecordInvalidatesWholeProjectionWithoutTruncation() throws {
        let valid = A4aFixture.definition(
            "Valid",
            fields: [A4aFixture.field("value", "uint64_t")],
            id: 1
        )
        let unsupported = A4aFixture.definition(
            "LegacyPointer",
            fields: [FieldDef(name: "ambiguous", type: "void *")],
            id: 2
        )
        assertInvalid(
            project(try A4aFixture.snapshotAdmittingCatalog(typeDefinitions: [valid, unsupported])),
            category: .unsupported,
            code: "authoring-input-unsupported",
            subject: "record-field"
        )
    }

    func testClassifiesExactFunctionStartsLiveExecutableInstructionsAndData() throws {
        let instructionAddress = A4aFixture.selectedFunctionStart + 0x100
        let dataAddress = A4aFixture.readableDataStart + 0x80
        let projection = try requireValid(A4aFixture.snapshot(
            selectedOverrides: [
                dataAddress: .init(customName: "data_subject"),
                instructionAddress: .init(customName: "label_subject"),
                A4aFixture.selectedFunctionStart: .init(customName: "function_subject"),
            ],
            selectedInstructions: [
                A4aFixture.instruction(address: A4aFixture.selectedFunctionStart),
                A4aFixture.instruction(address: instructionAddress),
            ]
        ))

        XCTAssertEqual(
            projection.authoredInputs.names.map(\.address.value),
            [A4aFixture.selectedFunctionStart, instructionAddress, dataAddress]
        )
        XCTAssertEqual(
            projection.authoredInputs.names.map(\.subjectKind),
            [.function, .label, .data]
        )
        XCTAssertEqual(
            projection.authoredInputs.names.map(\.name),
            ["function_subject", "label_subject", "data_subject"]
        )
    }

    func testEmptyDataShapeOverrideDoesNotSuppressInstructionCode() throws {
        let codeAddress = A4aFixture.selectedFunctionStart + 0x100
        let emptyShape = DataShapeOverride(kind: .array, elementCount: 0)
        XCTAssertTrue(emptyShape.isEmpty)

        let named = try requireValid(try A4aFixture.snapshot(
            selectedOverrides: [
                codeAddress: .init(customName: "still_live_code", dataShape: emptyShape),
            ],
            selectedInstructions: [A4aFixture.instruction(address: codeAddress)]
        ))
        XCTAssertEqual(named.authoredInputs.names.single?.subjectKind, .label)

        let scalar = A4aFixture.definition(
            "Scalar",
            fields: [A4aFixture.field("value", "uint64_t")],
            id: 104
        )
        assertInvalid(
            project(try A4aFixture.snapshot(
                selectedOverrides: [
                    codeAddress: .init(appliedTypeName: "Scalar", dataShape: emptyShape),
                ],
                selectedInstructions: [A4aFixture.instruction(address: codeAddress)],
                typeDefinitions: [scalar]
            )),
            category: .invalid,
            code: "authoring-input-invalid",
            subject: "applied-type"
        )
    }

    func testCodeDataRangesSuppressInstructionClassificationAndOverlap() throws {
        let dataAddress = A4aFixture.selectedFunctionStart + 0x100
        let inlineData = A4aFixture.codeDataRange(address: dataAddress, size: 4, id: 1)
        let named = try requireValid(try A4aFixture.snapshot(
            selectedOverrides: [dataAddress: .init(customName: "loader_data")],
            selectedInstructions: [A4aFixture.instruction(address: dataAddress)],
            selectedCodeDataRanges: [inlineData]
        ))
        XCTAssertEqual(named.authoredInputs.names.single?.subjectKind, .data)

        let scalar = A4aFixture.definition(
            "Scalar",
            fields: [A4aFixture.field("value", "uint64_t")],
            id: 105
        )
        let applied = try requireValid(try A4aFixture.snapshot(
            selectedOverrides: [dataAddress: .init(appliedTypeName: "Scalar")],
            selectedInstructions: [A4aFixture.instruction(address: dataAddress)],
            selectedCodeDataRanges: [inlineData],
            typeDefinitions: [scalar]
        ))
        XCTAssertEqual(applied.authoredInputs.appliedTypes.single?.byteCount.value, 8)
    }

    func testCodeDataRangeBeginningInsideInstructionDoesNotSuppressItsStart() throws {
        let instructionAddress = A4aFixture.selectedFunctionStart + 0x100
        let partialData = A4aFixture.codeDataRange(
            address: instructionAddress + 2,
            size: 1,
            id: 2
        )
        let named = try requireValid(try A4aFixture.snapshot(
            selectedOverrides: [instructionAddress: .init(customName: "live_start")],
            selectedInstructions: [A4aFixture.instruction(address: instructionAddress)],
            selectedCodeDataRanges: [partialData]
        ))
        XCTAssertEqual(named.authoredInputs.names.single?.subjectKind, .label)

        let scalar = A4aFixture.definition(
            "Scalar",
            fields: [A4aFixture.field("value", "uint64_t")],
            id: 110
        )
        assertInvalid(
            project(try A4aFixture.snapshot(
                selectedOverrides: [
                    instructionAddress: .init(appliedTypeName: "Scalar"),
                ],
                selectedInstructions: [A4aFixture.instruction(address: instructionAddress)],
                selectedCodeDataRanges: [partialData],
                typeDefinitions: [scalar]
            )),
            category: .invalid,
            code: "authoring-input-invalid",
            subject: "applied-type"
        )
    }

    func testNaturalPaddingPackingAndAggregateMinimumAlignmentAreExact() throws {
        let fields = [A4aFixture.field("small", "uint8_t"), A4aFixture.field("wide", "uint64_t")]
        let natural = A4aFixture.definition("Natural", fields: fields, id: 1)
        let packed = A4aFixture.definition(
            "Packed",
            fields: fields,
            layout: .init(isPacked: true),
            id: 2
        )
        let aggregateAligned = A4aFixture.definition(
            "AggregateAligned",
            fields: fields,
            layout: .init(minimumAlignment: 32),
            id: 3
        )

        XCTAssertEqual(try appliedByteCount(of: "Natural", definitions: [natural]), 16)
        XCTAssertEqual(try appliedByteCount(of: "Packed", definitions: [packed]), 9)
        XCTAssertEqual(
            try appliedByteCount(of: "AggregateAligned", definitions: [aggregateAligned]),
            32
        )
    }

    func testFieldNumericAndTypeMinimumAlignmentRaiseThenPackCaps() throws {
        let numeric = A4aFixture.definition(
            "NumericAligned",
            fields: [
                A4aFixture.field("head", "uint8_t"),
                A4aFixture.field("body", "uint32_t", minimumAlignment: 8),
            ],
            id: 1
        )
        let numericCapped = A4aFixture.definition(
            "NumericCapped",
            fields: [
                A4aFixture.field("head", "uint8_t"),
                A4aFixture.field("body", "uint32_t", minimumAlignment: 8),
            ],
            layout: .init(packAlignment: 4),
            id: 2
        )
        let typeAligned = A4aFixture.definition(
            "TypeAligned",
            fields: [
                A4aFixture.field("head", "uint8_t"),
                A4aFixture.field("body", "uint32_t", minimumAlignmentType: "uint64_t"),
            ],
            id: 3
        )
        let typeCapped = A4aFixture.definition(
            "TypeCapped",
            fields: [
                A4aFixture.field("head", "uint8_t"),
                A4aFixture.field("body", "uint32_t", minimumAlignmentType: "uint64_t"),
            ],
            layout: .init(packAlignment: 4),
            id: 4
        )

        XCTAssertEqual(try appliedByteCount(of: "NumericAligned", definitions: [numeric]), 16)
        XCTAssertEqual(try appliedByteCount(of: "NumericCapped", definitions: [numericCapped]), 8)
        XCTAssertEqual(try appliedByteCount(of: "TypeAligned", definitions: [typeAligned]), 16)
        XCTAssertEqual(try appliedByteCount(of: "TypeCapped", definitions: [typeCapped]), 8)
    }

    func testNamedAndInlineUnionLayoutAndPromotedFieldsAreExact() throws {
        let namedUnion = A4aFixture.definition(
            "Payload",
            kind: .union,
            fields: [A4aFixture.field("small", "uint8_t"), A4aFixture.field("wide", "uint64_t")],
            id: 1
        )
        let namedOwner = A4aFixture.definition(
            "NamedOwner",
            fields: [
                A4aFixture.field("tag", "uint8_t"),
                A4aFixture.field("payload", "Payload"),
            ],
            id: 2
        )
        let inlineOwner = A4aFixture.definition(
            "InlineOwner",
            fields: [
                A4aFixture.field("tag", "uint8_t"),
                A4aFixture.field(
                    "payload",
                    "ignored-placeholder",
                    inlineKind: .union,
                    inlineFields: [
                        A4aFixture.field("small", "uint8_t"),
                        A4aFixture.field("wide", "uint64_t"),
                    ]
                ),
            ],
            id: 3
        )
        let promotedOwner = A4aFixture.definition(
            "PromotedOwner",
            fields: [
                A4aFixture.field("tag", "uint8_t"),
                A4aFixture.field(
                    "",
                    "ignored-placeholder",
                    inlineKind: .union,
                    inlineFields: [
                        A4aFixture.field("small", "uint8_t"),
                        A4aFixture.field("wide", "uint64_t"),
                    ],
                    promotesInlineFields: true
                ),
            ],
            id: 4
        )

        XCTAssertEqual(
            try appliedByteCount(of: "NamedOwner", definitions: [namedUnion, namedOwner]),
            16
        )
        XCTAssertEqual(try appliedByteCount(of: "InlineOwner", definitions: [inlineOwner]), 16)
        XCTAssertEqual(try appliedByteCount(of: "PromotedOwner", definitions: [promotedOwner]), 16)

        let projected = try requireValid(
            try A4aFixture.snapshotAdmittingCatalog(typeDefinitions: [promotedOwner])
        ).authoredInputs.typeDefinitions.single
        guard case let .record(_, _, _, fields)? = projected,
              case let .inlineAggregate(_, _, inlineFields) = fields[1].storage else {
            return XCTFail("anonymous promoted union must remain structured authority")
        }
        XCTAssertTrue(fields[1].promotesInlineFields)
        XCTAssertEqual(inlineFields.map(\.name), ["small", "wide"])
    }

    func testBitfieldsShareStorageSpillAndAnonymousZeroWidthResets() throws {
        let shared = A4aFixture.definition(
            "SharedBits",
            fields: [
                A4aFixture.field("a", "uint32_t", bitWidth: 3),
                A4aFixture.field("b", "uint32_t", bitWidth: 5),
                A4aFixture.field("c", "uint32_t", bitWidth: 24),
            ],
            id: 1
        )
        let spilled = A4aFixture.definition(
            "SpilledBits",
            fields: shared.fields + [A4aFixture.field("d", "uint32_t", bitWidth: 1)],
            id: 2
        )
        let reset = A4aFixture.definition(
            "ResetBits",
            fields: [
                A4aFixture.field("a", "uint32_t", bitWidth: 3),
                A4aFixture.field("", "uint32_t", bitWidth: 0),
                A4aFixture.field("b", "uint32_t", bitWidth: 3),
            ],
            id: 3
        )

        XCTAssertEqual(try appliedByteCount(of: "SharedBits", definitions: [shared]), 4)
        XCTAssertEqual(try appliedByteCount(of: "SpilledBits", definitions: [spilled]), 8)
        XCTAssertEqual(try appliedByteCount(of: "ResetBits", definitions: [reset]), 8)
    }

    func testPackedAndPackOneMixedWidthBitfieldsUseBitPrecision() throws {
        let fields = [
            A4aFixture.field("first", "uint8_t", bitWidth: 7),
            A4aFixture.field("middle", "uint16_t", bitWidth: 10),
            A4aFixture.field("last", "uint8_t", bitWidth: 7),
        ]
        let packed = A4aFixture.definition(
            "PackedMixedBits",
            fields: fields,
            layout: .init(isPacked: true),
            id: 110
        )
        let packOne = A4aFixture.definition(
            "PackOneMixedBits",
            fields: fields,
            layout: .init(packAlignment: 1),
            id: 111
        )
        let packEight = A4aFixture.definition(
            "PackEightMixedBits",
            fields: fields,
            layout: .init(packAlignment: 8),
            id: 118
        )

        XCTAssertEqual(try appliedByteCount(of: "PackedMixedBits", definitions: [packed]), 3)
        XCTAssertEqual(try appliedByteCount(of: "PackOneMixedBits", definitions: [packOne]), 3)
        // Clang's Darwin arm64 layout keeps the 24 bits contiguous, then rounds size 3 to
        // aggregate alignment 2 because the u16 member's natural alignment is below pack(8).
        XCTAssertEqual(try appliedByteCount(of: "PackEightMixedBits", definitions: [packEight]), 4)
    }

    func testPackedAndPackOneZeroWidthBitfieldUsesUncappedNaturalBarrier() throws {
        let fields = [
            A4aFixture.field("head", "uint8_t"),
            A4aFixture.field("", "uint64_t", bitWidth: 0),
            A4aFixture.field("tail", "uint8_t"),
        ]
        let packed = A4aFixture.definition(
            "PackedZeroBarrier",
            fields: fields,
            layout: .init(isPacked: true),
            id: 112
        )
        let packOne = A4aFixture.definition(
            "PackOneZeroBarrier",
            fields: fields,
            layout: .init(packAlignment: 1),
            id: 113
        )

        // Exact size 9 proves the anonymous u64:0 advanced the tail to byte offset 8.
        XCTAssertEqual(try appliedByteCount(of: "PackedZeroBarrier", definitions: [packed]), 9)
        XCTAssertEqual(try appliedByteCount(of: "PackOneZeroBarrier", definitions: [packOne]), 9)
    }

    func testPackedAndPackOneUnionBitfieldUsesOnlyOccupiedBytes() throws {
        let fields = [A4aFixture.field("flag", "uint32_t", bitWidth: 1)]
        let packed = A4aFixture.definition(
            "PackedBitUnion",
            kind: .union,
            fields: fields,
            layout: .init(isPacked: true),
            id: 114
        )
        let packOne = A4aFixture.definition(
            "PackOneBitUnion",
            kind: .union,
            fields: fields,
            layout: .init(packAlignment: 1),
            id: 115
        )

        XCTAssertEqual(try appliedByteCount(of: "PackedBitUnion", definitions: [packed]), 1)
        XCTAssertEqual(try appliedByteCount(of: "PackOneBitUnion", definitions: [packOne]), 1)
    }

    func testRejectsNamedZeroWidthBitfield() throws {
        let invalid = A4aFixture.definition(
            "NamedZero",
            fields: [A4aFixture.field("must_not_be_named", "uint32_t", bitWidth: 0)],
            id: 1
        )
        assertInvalid(
            project(try A4aFixture.snapshotAdmittingCatalog(typeDefinitions: [invalid])),
            category: .invalid,
            code: "authoring-input-invalid",
            subject: "type-layout"
        )
    }

    func testMultidimensionalArraysAndTypedefChainsUseExactLayout() throws {
        let matrix = A4aFixture.definition(
            "Matrix",
            fields: [A4aFixture.field("values", "uint16_t[2][3]")],
            id: 1
        )
        let u16 = A4aFixture.definition(
            "U16",
            kind: .typedef,
            fields: [A4aFixture.field("U16", "uint16_t")],
            id: 2
        )
        let matrixAlias = A4aFixture.definition(
            "MatrixAlias",
            kind: .typedef,
            fields: [A4aFixture.field("MatrixAlias", "U16[2][3]")],
            id: 3
        )
        let alias2 = A4aFixture.definition(
            "MatrixAlias2",
            kind: .typedef,
            fields: [A4aFixture.field("MatrixAlias2", "MatrixAlias")],
            id: 4
        )

        XCTAssertEqual(try appliedByteCount(of: "Matrix", definitions: [matrix]), 12)
        XCTAssertEqual(
            try appliedByteCount(of: "MatrixAlias2", definitions: [u16, matrixAlias, alias2]),
            12
        )

        let projected = try requireValid(
            try A4aFixture.snapshotAdmittingCatalog(typeDefinitions: [matrix])
        ).authoredInputs.typeDefinitions.single
        guard case let .record(_, _, _, fields)? = projected,
              case let .fixedArray(outer, outerCount) = fields[0].storage,
              case let .fixedArray(_, innerCount) = outer else {
            return XCTFail("both persisted array dimensions must remain structured")
        }
        XCTAssertEqual(outerCount.value, 2)
        XCTAssertEqual(innerCount.value, 3)
    }

    func testFinalStructFlexibleArrayPropagatesThroughNamedAndTypedefEdges() throws {
        let tail = A4aFixture.definition(
            "Tail",
            fields: [
                A4aFixture.field("count", "uint32_t"),
                A4aFixture.field("bytes", "uint8_t[]"),
            ],
            id: 1
        )
        let tailAlias = A4aFixture.definition(
            "TailAlias",
            kind: .typedef,
            fields: [A4aFixture.field("TailAlias", "Tail")],
            id: 2
        )
        let namedOuter = A4aFixture.definition(
            "NamedOuter",
            fields: [
                A4aFixture.field("prefix", "uint8_t"),
                A4aFixture.field("tail", "Tail"),
            ],
            id: 3
        )
        let aliasOuter = A4aFixture.definition(
            "AliasOuter",
            fields: [
                A4aFixture.field("prefix", "uint8_t"),
                A4aFixture.field("tail", "TailAlias"),
            ],
            id: 4
        )

        XCTAssertEqual(
            try appliedByteCount(of: "NamedOuter", definitions: [tail, namedOuter]),
            8
        )
        XCTAssertEqual(
            try appliedByteCount(of: "AliasOuter", definitions: [tail, tailAlias, aliasOuter]),
            8
        )
    }

    func testFlexibleArrayRejectsArrayUnionAndNonfinalBarriers() throws {
        let tail = A4aFixture.definition(
            "Tail",
            fields: [
                A4aFixture.field("count", "uint32_t"),
                A4aFixture.field("bytes", "uint8_t[]"),
            ],
            id: 1
        )
        let barriers = [
            A4aFixture.definition(
                "ArrayBarrier",
                fields: [A4aFixture.field("tails", "Tail[2]")],
                id: 2
            ),
            A4aFixture.definition(
                "UnionBarrier",
                kind: .union,
                fields: [A4aFixture.field("tail", "Tail")],
                id: 3
            ),
            A4aFixture.definition(
                "NonfinalBarrier",
                fields: [A4aFixture.field("tail", "Tail"), A4aFixture.field("after", "uint8_t")],
                id: 4
            ),
        ]

        for barrier in barriers {
            assertInvalid(
                project(try A4aFixture.snapshotAdmittingCatalog(typeDefinitions: [tail, barrier])),
                category: .unsupported,
                code: "authoring-input-unsupported",
                subject: "type-layout"
            )
        }
    }

    func testPointerCyclesAreAcceptedButByValueAndAlignmentCyclesAreRejected() throws {
        let pointer = A4aFixture.definition(
            "PointerNode",
            fields: [A4aFixture.field("next", "PointerNode *")],
            id: 1
        )
        XCTAssertEqual(try appliedByteCount(of: "PointerNode", definitions: [pointer]), 8)

        let valueA = A4aFixture.definition(
            "ValueA",
            fields: [A4aFixture.field("b", "ValueB")],
            id: 2
        )
        let valueB = A4aFixture.definition(
            "ValueB",
            fields: [A4aFixture.field("a", "ValueA")],
            id: 3
        )
        assertInvalid(
            project(try A4aFixture.snapshotAdmittingCatalog(typeDefinitions: [valueA, valueB])),
            category: .unsupported,
            code: "authoring-input-unsupported",
            subject: "type-layout"
        )

        let alignedA = A4aFixture.definition(
            "AlignedA",
            fields: [A4aFixture.field("value", "uint32_t", minimumAlignmentType: "AlignedB")],
            id: 4
        )
        let alignedB = A4aFixture.definition(
            "AlignedB",
            fields: [A4aFixture.field("value", "uint32_t", minimumAlignmentType: "AlignedA")],
            id: 5
        )
        assertInvalid(
            project(try A4aFixture.snapshotAdmittingCatalog(typeDefinitions: [alignedA, alignedB])),
            category: .unsupported,
            code: "authoring-input-unsupported",
            subject: "type-layout"
        )
    }

    func testStorageLayoutAcceptsExactlyOneMiBAndRejectsLimitPlusOne() throws {
        let exact = A4aFixture.definition(
            "ExactMiB",
            fields: [A4aFixture.field("bytes", "uint8_t[1048576]")],
            id: 1
        )
        XCTAssertEqual(try appliedByteCount(of: "ExactMiB", definitions: [exact]), 1_048_576)

        let plusOne = A4aFixture.definition(
            "OverMiB",
            fields: [A4aFixture.field("words", "uint64_t[131073]")],
            id: 2
        )
        assertInvalid(
            project(try A4aFixture.snapshotAdmittingCatalog(typeDefinitions: [plusOne])),
            category: .bounds,
            code: "authoring-input-too-large",
            subject: "type-layout"
        )

        let countPlusOne = A4aFixture.definition(
            "OverElementCount",
            fields: [A4aFixture.field("bytes", "uint8_t[1048577]")],
            id: 3
        )
        assertInvalid(
            project(try A4aFixture.snapshotAdmittingCatalog(typeDefinitions: [countPlusOne])),
            category: .bounds,
            code: "authored-field-storage-bounds",
            subject: "record-field"
        )
    }

    func testAppliedTypeByteCountIncludesFinalAggregatePadding() throws {
        let padded = A4aFixture.definition(
            "Padded",
            fields: [A4aFixture.field("wide", "uint64_t"), A4aFixture.field("tail", "uint8_t")],
            id: 1
        )
        let projection = try requireValid(try A4aFixture.snapshot(
            selectedOverrides: [
                A4aFixture.readableDataStart: .init(appliedTypeName: "Padded"),
            ],
            typeDefinitions: [padded]
        ))
        XCTAssertEqual(projection.authoredInputs.appliedTypes.single?.byteCount.value, 16)
        XCTAssertNotEqual(projection.authoredInputs.appliedTypes.single?.byteCount.value, 9)
    }

    func testAppliedTypeRequiresExactlyOneReadableSpanIncludingZeroFill() throws {
        let scalar = A4aFixture.definition(
            "Scalar",
            fields: [A4aFixture.field("value", "uint64_t")],
            id: 1
        )
        let zeroFillStart = A4aFixture.readableDataStart + 0x20_0000
        let zeroFill = A4aFixture.segment(
            "__BSS",
            vmStart: zeroFillStart,
            vmSize: 0x1000,
            fileOffset: 0x2000,
            fileSize: 0,
            protections: 3
        )
        let validZeroFill = try A4aFixture.snapshot(
            selectedOverrides: [zeroFillStart: .init(appliedTypeName: "Scalar")],
            preferredSegments: A4aFixture.defaultSegments + [zeroFill],
            typeDefinitions: [scalar]
        )
        XCTAssertEqual(
            try requireValid(validZeroFill).authoredInputs.appliedTypes.single?.byteCount.value,
            8
        )

        let splitStart = A4aFixture.readableDataStart + 0x100
        let splitRecords = [
            A4aFixture.defaultSegments[0],
            A4aFixture.segment(
                "__D1",
                vmStart: splitStart,
                vmSize: 4,
                fileOffset: 0x1000,
                fileSize: 4,
                protections: 3
            ),
            A4aFixture.segment(
                "__D2",
                vmStart: splitStart + 4,
                vmSize: 0x100,
                fileOffset: 0x1004,
                fileSize: 0x100,
                protections: 3
            ),
        ]
        let split = try A4aFixture.snapshot(
            selectedOverrides: [splitStart: .init(appliedTypeName: "Scalar")],
            preferredSegments: splitRecords,
            typeDefinitions: [scalar]
        )
        assertInvalid(
            project(split),
            category: .invalid,
            code: "authoring-input-invalid",
            subject: "applied-type"
        )
    }

    func testAppliedAndReadableSpanOverflowFailClosedWithStableDiagnostic() throws {
        let wide = A4aFixture.definition(
            "OverflowWide",
            fields: [A4aFixture.field("value", "uint64_t")],
            id: 116
        )
        assertInvalid(
            project(try A4aFixture.snapshot(
                selectedOverrides: [
                    UInt64.max - 3: .init(appliedTypeName: "OverflowWide"),
                ],
                selectedInstructions: [],
                typeDefinitions: [wide]
            )),
            category: .invalid,
            code: "authoring-input-invalid",
            subject: "applied-type"
        )

        let byte = A4aFixture.definition(
            "OverflowRegionByte",
            fields: [A4aFixture.field("value", "uint8_t")],
            id: 117
        )
        let address = UInt64.max - 16
        var malformedAuthority = try A4aFixture.snapshot(
            selectedOverrides: [address: .init(appliedTypeName: "OverflowRegionByte")],
            selectedInstructions: [],
            typeDefinitions: [byte]
        )
        malformedAuthority.binaries[0].preferredSegmentLayout =
            A4aFixture.uncheckedPreferredSegmentLayout(records: [
                A4aFixture.segment(
                    "__OVERFLOW",
                    vmStart: UInt64.max - 32,
                    vmSize: 64,
                    fileOffset: 0,
                    fileSize: 0,
                    protections: 1
                ),
            ])
        assertInvalid(
            project(malformedAuthority),
            category: .invalid,
            code: "authoring-input-invalid",
            subject: "applied-type"
        )
    }

    func testAppliedTypeFunctionAndInstructionOverlapUseHalfOpenBounds() throws {
        let byte = A4aFixture.definition(
            "Byte",
            fields: [A4aFixture.field("value", "uint8_t")],
            id: 1
        )
        let atFunctionEnd = try A4aFixture.snapshot(
            selectedOverrides: [
                A4aFixture.selectedFunctionEnd: .init(appliedTypeName: "Byte"),
            ],
            typeDefinitions: [byte]
        )
        XCTAssertEqual(
            try requireValid(atFunctionEnd).authoredInputs.appliedTypes.single?.address.value,
            A4aFixture.selectedFunctionEnd
        )

        let beforeFunctionEnd = try A4aFixture.snapshot(
            selectedOverrides: [
                A4aFixture.selectedFunctionEnd - 1: .init(appliedTypeName: "Byte"),
            ],
            typeDefinitions: [byte]
        )
        assertInvalid(
            project(beforeFunctionEnd),
            category: .invalid,
            code: "authoring-input-invalid",
            subject: "applied-type"
        )

        let instructionAddress = A4aFixture.selectedFunctionStart + 0x100
        let atInstructionEnd = try A4aFixture.snapshot(
            selectedOverrides: [instructionAddress + 4: .init(appliedTypeName: "Byte")],
            selectedInstructions: [A4aFixture.instruction(address: instructionAddress)],
            typeDefinitions: [byte]
        )
        XCTAssertEqual(
            try requireValid(atInstructionEnd).authoredInputs.appliedTypes.single?.address.value,
            instructionAddress + 4
        )
        let beforeInstructionEnd = try A4aFixture.snapshot(
            selectedOverrides: [instructionAddress + 3: .init(appliedTypeName: "Byte")],
            selectedInstructions: [A4aFixture.instruction(address: instructionAddress)],
            typeDefinitions: [byte]
        )
        assertInvalid(
            project(beforeInstructionEnd),
            category: .invalid,
            code: "authoring-input-invalid",
            subject: "applied-type"
        )
    }

    func testDiagnosticIdentitiesUseStableLowCardinalitySubjects() throws {
        var firstSnapshot = try A4aFixture.snapshot(selectedOverrides: [
            A4aFixture.readableDataStart: .init(customName: "bad\u{7f}name"),
        ])
        firstSnapshot.binaries[0].path = "/private/raw/path/one"
        var secondSnapshot = try A4aFixture.snapshot(selectedOverrides: [
            A4aFixture.readableDataStart + 1: .init(customName: "different\u{1f}raw"),
        ])
        secondSnapshot.binaries[0].path = "/private/raw/path/two"

        let first = requireInvalidIdentity(
            project(firstSnapshot),
            category: .invalid,
            code: "authoring-input-invalid",
            subject: "authored-name"
        )
        let second = requireInvalidIdentity(
            project(secondSnapshot),
            category: .invalid,
            code: "authoring-input-invalid",
            subject: "authored-name"
        )
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.imageSlot, A4aFixture.selectedSlot)
        XCTAssertFalse(first.code.contains("bad"))
        XCTAssertFalse(first.subject.contains("/"))
    }

    func testEmptyCustomNameIsInertBesideActiveSignatureAuthority() throws {
        let signature = FunctionSignatureOverride(noReturnState: .noReturn)
        let baseline = try requireValid(try A4aFixture.snapshot(selectedOverrides: [
            A4aFixture.selectedFunctionStart: .init(signature: signature),
        ]))
        let emptyName = try requireValid(try A4aFixture.snapshot(selectedOverrides: [
            A4aFixture.selectedFunctionStart: .init(customName: "", signature: signature),
        ]))

        XCTAssertEqual(emptyName.authoredInputs.names, [])
        XCTAssertEqual(emptyName.authoredInputs.signatures.single?.noReturnState, .noReturn)
        XCTAssertEqual(emptyName.authoredInputs, baseline.authoredInputs)
        XCTAssertEqual(emptyName.canonicalIdentitySHA256, baseline.canonicalIdentitySHA256)
        XCTAssertEqual(emptyName.canonicalByteCount, baseline.canonicalByteCount)
    }

    func testInlineAggregatePrepassChecksDepthBeforeDescending() throws {
        let atLimit = A4aFixture.definition(
            "InlineDepth16",
            fields: [A4aFixture.inlineChain(depth: 16)],
            id: 106
        )
        XCTAssertEqual(try appliedByteCount(of: "InlineDepth16", definitions: [atLimit]), 1)

        let overLimit = A4aFixture.definition(
            "InlineDepth17",
            fields: [A4aFixture.inlineChain(depth: 17)],
            id: 107
        )
        assertInvalid(
            project(try A4aFixture.snapshotAdmittingCatalog(typeDefinitions: [overLimit])),
            category: .bounds,
            code: "authored-field-storage-bounds",
            subject: "record-field"
        )

        let deepButBounded = A4aFixture.definition(
            "HostileDepth",
            fields: [A4aFixture.inlineChain(depth: 20_000)],
            id: 108
        )
        assertInvalid(
            project(try A4aFixture.snapshotAdmittingCatalog(typeDefinitions: [deepButBounded])),
            category: .bounds,
            code: "authored-aggregate-members-count",
            subject: "type-catalog"
        )
    }

    func testInstructionEndOverflowRemainsConservativelyCode() throws {
        let malformedAddress = UInt64.max - 1
        let malformed = A4aFixture.instruction(address: malformedAddress, bytes: "aa bb")
        let named = try requireValid(try A4aFixture.snapshot(
            selectedOverrides: [malformedAddress: .init(customName: "malformed_code")],
            selectedInstructions: [malformed]
        ))
        XCTAssertEqual(named.authoredInputs.names.single?.subjectKind, .label)

        let scalar = A4aFixture.definition(
            "Scalar",
            fields: [A4aFixture.field("value", "uint64_t")],
            id: 109
        )
        assertInvalid(
            project(try A4aFixture.snapshot(
                selectedOverrides: [
                    A4aFixture.readableDataStart: .init(appliedTypeName: "Scalar"),
                ],
                selectedInstructions: [malformed],
                typeDefinitions: [scalar]
            )),
            category: .invalid,
            code: "authoring-input-invalid",
            subject: "applied-type"
        )
    }

    func testInvalidIdentityIsDeterministicAcrossReversedSemanticInputOrder() throws {
        let overlongType = String(repeating: "x", count: 4_097)
        let overlongName = String(repeating: "n", count: 1_025)

        let nameEntries: [(UInt64, AddressOverride)] = [
            (
                A4aFixture.readableDataStart,
                .init(customName: "invalid\u{1f}name")
            ),
        ] + (1 ... 31).map { index in
            (
                A4aFixture.readableDataStart + UInt64(index),
                AddressOverride(customName: overlongName)
            )
        }
        let expectedNameIdentity = NativeDecompilerSemanticInputIdentity.invalid(
            .init(
                code: "authoring-input-invalid",
                imageSlot: A4aFixture.selectedSlot,
                subject: "authored-name"
            )
        )
        XCTAssertEqual(
            project(try A4aFixture.snapshot(
                selectedOverrides: A4aFixture.overrides(inInsertionOrder: nameEntries)
            )).identity,
            expectedNameIdentity
        )
        XCTAssertEqual(
            project(try A4aFixture.snapshot(
                selectedOverrides: A4aFixture.overrides(
                    inInsertionOrder: Array(nameEntries.reversed())
                )
            )).identity,
            expectedNameIdentity
        )

        let functions = A4aFixture.functions(count: 32)
        let signatureEntries: [(UInt64, AddressOverride)] = functions.enumerated().map {
            index,
            function in
            (
                function.startAddress,
                .init(signature: .init(returnType: index == 0 ? "!" : overlongType))
            )
        }
        let expectedSignatureIdentity = NativeDecompilerSemanticInputIdentity.invalid(
            .init(
                code: "authored-type-grammar",
                imageSlot: A4aFixture.selectedSlot,
                subject: "authored-type"
            )
        )
        XCTAssertEqual(
            project(try A4aFixture.snapshot(
                selectedOverrides: A4aFixture.overrides(inInsertionOrder: signatureEntries),
                selectedFunctions: functions
            )).identity,
            expectedSignatureIdentity
        )
        XCTAssertEqual(
            project(try A4aFixture.snapshot(
                selectedOverrides: A4aFixture.overrides(
                    inInsertionOrder: Array(signatureEntries.reversed())
                ),
                selectedFunctions: functions
            )).identity,
            expectedSignatureIdentity
        )

        let scalar = A4aFixture.definition(
            "Byte",
            fields: [A4aFixture.field("value", "uint8_t")],
            id: 110
        )
        let appliedEntries: [(UInt64, AddressOverride)] = [
            (A4aFixture.selectedFunctionStart, .init(appliedTypeName: "Byte")),
            (UInt64.max, .init(appliedTypeName: "Byte")),
        ]
        let expectedAppliedIdentity = NativeDecompilerSemanticInputIdentity.invalid(
            .init(
                code: "authoring-input-invalid",
                imageSlot: A4aFixture.selectedSlot,
                subject: "applied-type"
            )
        )
        XCTAssertEqual(
            project(try A4aFixture.snapshot(
                selectedOverrides: A4aFixture.overrides(inInsertionOrder: appliedEntries),
                typeDefinitions: [scalar]
            )).identity,
            expectedAppliedIdentity
        )
        XCTAssertEqual(
            project(try A4aFixture.snapshot(
                selectedOverrides: A4aFixture.overrides(
                    inInsertionOrder: Array(appliedEntries.reversed())
                ),
                typeDefinitions: [scalar]
            )).identity,
            expectedAppliedIdentity
        )

        let invalidFirstByUTF8 = A4aFixture.definition(
            "A\u{1f}",
            fields: [],
            id: 111
        )
        let boundedSecondByUTF8 = A4aFixture.definition(
            String(repeating: "Z", count: 4_097),
            fields: [],
            id: 112
        )
        let expectedCatalogIdentity = NativeDecompilerSemanticInputIdentity.invalid(
            .init(
                code: "authoring-input-invalid",
                imageSlot: A4aFixture.selectedSlot,
                subject: "type-catalog"
            )
        )
        XCTAssertEqual(
            project(try A4aFixture.snapshot(
                typeDefinitions: [invalidFirstByUTF8, boundedSecondByUTF8]
            )).identity,
            expectedCatalogIdentity
        )
        XCTAssertEqual(
            project(try A4aFixture.snapshot(
                typeDefinitions: [boundedSecondByUTF8, invalidFirstByUTF8]
            )).identity,
            expectedCatalogIdentity
        )
    }

    func testAggregateAccountingAccepts16384SignatureParametersAndRejectsNext() throws {
        let functions = A4aFixture.functions(count: 65)
        let parameters = (0 ..< 256).map { index in
            ArgOverride(
                rowToken: "p\(index)",
                name: "p\(index)",
                type: "uint8_t"
            )
        }
        let atLimitEntries: [(UInt64, AddressOverride)] = functions.prefix(64).map { function in
            (
                function.startAddress,
                .init(signature: .init(parameterList: .authoritative(parameters)))
            )
        }
        let aggregateBoundsIdentity = NativeDecompilerSemanticInputIdentity.invalid(
            .init(
                code: "authored-aggregate-members-count",
                imageSlot: A4aFixture.selectedSlot,
                subject: "type-catalog"
            )
        )

        let atLimit = project(try A4aFixture.snapshot(
            selectedOverrides: A4aFixture.overrides(inInsertionOrder: atLimitEntries),
            selectedFunctions: functions
        ))
        XCTAssertNotEqual(atLimit.identity, aggregateBoundsIdentity)

        let overLimitEntries = atLimitEntries + [
            (
                functions[64].startAddress,
                .init(
                    signature: .init(
                        parameterList: .authoritative([
                            .init(rowToken: "overflow", name: "overflow", type: "uint8_t"),
                        ])
                    )
                )
            ),
        ]
        XCTAssertEqual(
            project(try A4aFixture.snapshot(
                selectedOverrides: A4aFixture.overrides(inInsertionOrder: overLimitEntries),
                selectedFunctions: functions
            )).identity,
            aggregateBoundsIdentity
        )
    }

    func testReturnedDTOIsExplicitlySortedAndIdentityMatchesOneCanonicalEncoding() throws {
        let definitions = [
            A4aFixture.definition("Zulu", fields: [A4aFixture.field("z", "uint8_t")], id: 2),
            A4aFixture.definition("Alpha", fields: [A4aFixture.field("a", "uint16_t")], id: 1),
        ]
        let snapshot = try A4aFixture.snapshot(
            selectedOverrides: [
                A4aFixture.readableDataStart + 8: .init(customName: "later", appliedTypeName: "Zulu"),
                A4aFixture.selectedFunctionStart: .init(customName: "first"),
                A4aFixture.readableDataStart: .init(customName: "middle", appliedTypeName: "Alpha"),
            ],
            typeDefinitions: definitions
        )
        let projection = try requireValid(snapshot)

        XCTAssertEqual(
            projection.authoredInputs.names.map(\.address.value),
            [A4aFixture.selectedFunctionStart, A4aFixture.readableDataStart, A4aFixture.readableDataStart + 8]
        )
        XCTAssertEqual(
            projection.authoredInputs.appliedTypes.map(\.address.value),
            [A4aFixture.readableDataStart, A4aFixture.readableDataStart + 8]
        )
        XCTAssertEqual(projection.authoredInputs.typeDefinitions.map(\.name), ["Alpha", "Zulu"])

        let canonical = try NativeDecompilerWireCanonicalRequest.canonicalAuthoredInputBytes(
            projection.authoredInputs
        )
        let digest = SHA256.hash(data: canonical).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(projection.canonicalByteCount, canonical.count)
        XCTAssertEqual(projection.canonicalIdentitySHA256, digest)
    }

    func testAuthoredCustomNameProjectionDoesNotClaimNativeDerivedSuppression() throws {
        let derived = A4aFixture.symbol(
            id: 1,
            name: "_derived",
            address: A4aFixture.selectedFunctionStart
        )
        let snapshot = try A4aFixture.snapshot(
            selectedOverrides: [
                A4aFixture.selectedFunctionStart: .init(customName: "authored"),
            ],
            selectedSymbols: [derived]
        )
        let projection = try requireValid(snapshot)

        XCTAssertEqual(projection.authoredInputs.names.map(\.name), ["authored"])
        XCTAssertEqual(snapshot.analysis(in: A4aFixture.selectedSlot)?.symbols, [derived])
        XCTAssertFalse(projection.authoredInputs.names.contains { $0.name == "_derived" })
    }

    private enum DiagnosticCategory: Equatable {
        case unsupported
        case invalid
        case bounds
    }

    private func project(_ snapshot: WorkspaceSnapshot) -> NativeDecompilerSemanticInputState {
        NativeDecompilerAuthoredInputProjector.project(
            workspace: snapshot,
            imageSlot: A4aFixture.selectedSlot,
            functionID: A4aFixture.selectedFunctionID
        )
    }

    private func requireValid(
        _ snapshot: WorkspaceSnapshot,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> NativeDecompilerAuthoredProjection {
        switch project(snapshot) {
        case let .valid(projection):
            return projection
        case let .invalid(diagnostic):
            XCTFail("expected valid projection, got \(diagnostic)", file: file, line: line)
            throw diagnostic
        }
    }

    @discardableResult
    private func assertInvalid(
        _ state: NativeDecompilerSemanticInputState,
        category: DiagnosticCategory,
        code: String,
        subject: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> NativeAuthoredProjectionDiagnostic.Identity {
        let identity = requireInvalidIdentity(
            state,
            category: category,
            code: code,
            subject: subject,
            file: file,
            line: line
        )
        XCTAssertEqual(identity.imageSlot, A4aFixture.selectedSlot, file: file, line: line)
        return identity
    }

    private func requireInvalidIdentity(
        _ state: NativeDecompilerSemanticInputState,
        category: DiagnosticCategory,
        code: String,
        subject: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> NativeAuthoredProjectionDiagnostic.Identity {
        let actualCategory: DiagnosticCategory
        let identity: NativeAuthoredProjectionDiagnostic.Identity
        switch state {
        case .valid:
            XCTFail("expected invalid semantic input", file: file, line: line)
            return .init(code: "test-missing-diagnostic", imageSlot: nil, subject: "test")
        case let .invalid(diagnostic):
            switch diagnostic {
            case let .unsupported(id):
                actualCategory = .unsupported
                identity = id
            case let .invalid(id):
                actualCategory = .invalid
                identity = id
            case let .bounds(id):
                actualCategory = .bounds
                identity = id
            }
        }
        XCTAssertEqual(actualCategory, category, file: file, line: line)
        XCTAssertEqual(identity.code, code, file: file, line: line)
        XCTAssertEqual(identity.subject, subject, file: file, line: line)
        return identity
    }

    private func appliedByteCount(
        of name: String,
        definitions: [TypeDefinition]
    ) throws -> UInt64 {
        let snapshot = try A4aFixture.snapshot(
            selectedOverrides: [
                A4aFixture.readableDataStart: .init(appliedTypeName: name),
            ],
            typeDefinitions: definitions
        )
        return try XCTUnwrap(requireValid(snapshot).authoredInputs.appliedTypes.single).byteCount.value
    }

    private func assertCollectionAndTextBounds() throws {
        let exactName = String(repeating: "n", count: 1_024)
        let exactNameProjection = try requireValid(try A4aFixture.snapshot(selectedOverrides: [
            A4aFixture.readableDataStart: .init(customName: exactName),
        ]))
        XCTAssertEqual(exactNameProjection.authoredInputs.names.single?.name.utf8.count, 1_024)

        assertInvalid(
            project(try A4aFixture.snapshot(selectedOverrides: [
                A4aFixture.readableDataStart: .init(
                    customName: String(repeating: "n", count: 1_025)
                ),
            ])),
            category: .bounds,
            code: "authored-semantic-name-bytes",
            subject: "authored-name"
        )
        for invalidText in ["control\u{1f}", "delete\u{7f}"] {
            assertInvalid(
                project(try A4aFixture.snapshot(selectedOverrides: [
                    A4aFixture.readableDataStart: .init(customName: invalidText),
                ])),
                category: .invalid,
                code: "authoring-input-invalid",
                subject: "authored-name"
            )
        }

        let namesAtLimit = Dictionary(uniqueKeysWithValues: (0 ..< 4_096).map { index in
            (
                A4aFixture.readableDataStart + UInt64(index),
                AddressOverride(customName: "n\(index)")
            )
        })
        XCTAssertEqual(
            try requireValid(
                try A4aFixture.snapshot(selectedOverrides: namesAtLimit)
            ).authoredInputs.names.count,
            4_096
        )
        var namesOverLimit = namesAtLimit
        namesOverLimit[A4aFixture.readableDataStart + 4_096] = .init(customName: "overflow")
        assertInvalid(
            project(try A4aFixture.snapshot(selectedOverrides: namesOverLimit)),
            category: .bounds,
            code: "authored-names-count",
            subject: "names"
        )

        let functionsAtSignatureLimit = A4aFixture.functions(count: 4_096)
        let signaturesAtLimit = Dictionary(uniqueKeysWithValues: functionsAtSignatureLimit.map {
            ($0.startAddress, AddressOverride(signature: .init(noReturnState: .returns)))
        })
        assertInvalid(
            project(try A4aFixture.snapshot(
                selectedOverrides: signaturesAtLimit,
                selectedFunctions: functionsAtSignatureLimit
            )),
            category: .bounds,
            code: "authored-canonical-bytes",
            subject: "root"
        )
        let functionsOverSignatureLimit = A4aFixture.functions(count: 4_097)
        let signaturesOverLimit = Dictionary(uniqueKeysWithValues: functionsOverSignatureLimit.map {
            ($0.startAddress, AddressOverride(signature: .init(noReturnState: .returns)))
        })
        assertInvalid(
            project(try A4aFixture.snapshot(
                selectedOverrides: signaturesOverLimit,
                selectedFunctions: functionsOverSignatureLimit
            )),
            category: .bounds,
            code: "authored-signatures-count",
            subject: "signatures"
        )

        let parametersAtLimit = (0 ..< 256).map {
            ArgOverride(rowToken: "p\($0)", name: "p\($0)", type: "uint64_t")
        }
        let parametersSnapshot = try A4aFixture.snapshot(selectedOverrides: [
            A4aFixture.selectedFunctionStart: .init(
                signature: .init(
                    parameterList: .authoritative(parametersAtLimit),
                    variadicState: .fixed
                )
            ),
        ])
        XCTAssertEqual(
            try requireValid(parametersSnapshot).authoredInputs.signatures.single?.parameters.count,
            256
        )
        let parametersOverLimit = parametersAtLimit + [
            ArgOverride(rowToken: "overflow", name: "overflow", type: "uint64_t"),
        ]
        assertInvalid(
            project(try A4aFixture.snapshot(selectedOverrides: [
                A4aFixture.selectedFunctionStart: .init(
                    signature: .init(
                        parameterList: .authoritative(parametersOverLimit),
                        variadicState: .fixed
                    )
                ),
            ])),
            category: .bounds,
            code: "authored-parameters-count",
            subject: "signature"
        )

        let byte = A4aFixture.definition(
            "B",
            fields: [A4aFixture.field("v", "uint8_t")],
            id: 1
        )
        let appliedAtLimit = Dictionary(uniqueKeysWithValues: (0 ..< 4_096).map { index in
            (
                A4aFixture.readableDataStart + UInt64(index),
                AddressOverride(appliedTypeName: "B")
            )
        })
        XCTAssertEqual(
            try requireValid(try A4aFixture.snapshot(
                selectedOverrides: appliedAtLimit,
                typeDefinitions: [byte]
            )).authoredInputs.appliedTypes.count,
            4_096
        )
        var appliedOverLimit = appliedAtLimit
        appliedOverLimit[A4aFixture.readableDataStart + 4_096] = .init(appliedTypeName: "B")
        assertInvalid(
            project(try A4aFixture.snapshot(
                selectedOverrides: appliedOverLimit,
                typeDefinitions: [byte]
            )),
            category: .bounds,
            code: "authored-applied-types-count",
            subject: "applied-types"
        )

        let definitionsAtLimit = (0 ..< 1_024).map { index in
            A4aFixture.definition("T\(index)", fields: [], id: index + 1)
        }
        XCTAssertEqual(
            try requireValid(
                try A4aFixture.snapshot(typeDefinitions: definitionsAtLimit)
            ).authoredInputs.typeDefinitions.count,
            0
        )
        let definitionsOverLimit = definitionsAtLimit + [
            A4aFixture.definition("OverflowType", fields: [], id: 1_025),
        ]
        assertInvalid(
            project(try A4aFixture.snapshot(typeDefinitions: definitionsOverLimit)),
            category: .bounds,
            code: "authored-type-definitions-count",
            subject: "type-catalog"
        )

        let exactCatalogName = String(repeating: "T", count: 4_096)
        let exactCatalog = A4aFixture.definition(exactCatalogName, fields: [], id: 2_001)
        XCTAssertEqual(
            try requireValid(
                try A4aFixture.snapshotAdmittingCatalog(typeDefinitions: [exactCatalog])
            ).authoredInputs.typeDefinitions.single?.name.utf8.count,
            4_096
        )
        let overCatalogName = String(repeating: "T", count: 4_097)
        let overCatalog = A4aFixture.definition(overCatalogName, fields: [], id: 2_002)
        assertInvalid(
            project(try A4aFixture.snapshotAdmittingCatalog(typeDefinitions: [overCatalog])),
            category: .bounds,
            code: "authored-catalog-text-bytes",
            subject: "type-catalog"
        )
    }

    private func assertDepthAndAggregateBounds() throws {
        let depth16 = "uint8_t" + String(repeating: "[1]", count: 16)
        let depth17 = "uint8_t" + String(repeating: "[1]", count: 17)
        let atLimit = A4aFixture.definition(
            "Depth16",
            fields: [A4aFixture.field("value", depth16)],
            id: 3_001
        )
        XCTAssertEqual(try appliedByteCount(of: "Depth16", definitions: [atLimit]), 1)
        let overLimit = A4aFixture.definition(
            "Depth17",
            fields: [A4aFixture.field("value", depth17)],
            id: 3_002
        )
        assertInvalid(
            project(try A4aFixture.snapshotAdmittingCatalog(typeDefinitions: [overLimit])),
            category: .bounds,
            code: "authored-field-storage-bounds",
            subject: "record-field"
        )

        let fieldsAtLimit = (0 ..< 16_384).map { index in
            A4aFixture.field("f\(index)", "uint8_t")
        }
        let aggregateAtLimit = A4aFixture.definition(
            "AggregateLimit",
            fields: fieldsAtLimit,
            id: 3_003
        )
        assertInvalid(
            project(try A4aFixture.snapshot(
                selectedOverrides: [
                    A4aFixture.readableDataStart: .init(appliedTypeName: "AggregateLimit"),
                ],
                typeDefinitions: [aggregateAtLimit]
            )),
            category: .bounds,
            code: "authored-canonical-bytes",
            subject: "root"
        )
        let aggregateOverLimit = A4aFixture.definition(
            "AggregateOverLimit",
            fields: fieldsAtLimit + [A4aFixture.field("overflow", "uint8_t")],
            id: 3_004
        )
        assertInvalid(
            project(try A4aFixture.snapshotAdmittingCatalog(typeDefinitions: [aggregateOverLimit])),
            category: .bounds,
            code: "authored-aggregate-members-count",
            subject: "type-catalog"
        )
    }

    private func assertCanonicalByteBoundary() throws {
        let lengths = A4aFixture.nameLengthsForExactCanonicalByteCount(1_048_576)
        XCTAssertFalse(lengths.isEmpty)
        XCTAssertLessThanOrEqual(lengths.count, 4_096)
        XCTAssertLessThan(lengths.last ?? .max, 1_024)

        func overrides(nameLengths: [Int]) -> [UInt64: AddressOverride] {
            Dictionary(uniqueKeysWithValues: nameLengths.enumerated().map { index, length in
                (
                    A4aFixture.readableDataStart + UInt64(index),
                    AddressOverride(customName: String(repeating: "x", count: length))
                )
            })
        }

        let exact = try requireValid(
            try A4aFixture.snapshot(selectedOverrides: overrides(nameLengths: lengths))
        )
        XCTAssertEqual(exact.canonicalByteCount, 1_048_576)

        var plusOneLengths = lengths
        plusOneLengths[plusOneLengths.index(before: plusOneLengths.endIndex)] += 1
        assertInvalid(
            project(try A4aFixture.snapshot(
                selectedOverrides: overrides(nameLengths: plusOneLengths)
            )),
            category: .bounds,
            code: "authored-canonical-bytes",
            subject: "root"
        )
    }
}

private enum A4aFixture {
    static let selectedSlot = ImageSlot(rawValue: 7)
    static let siblingSlot = ImageSlot(rawValue: 8)
    static let selectedBinaryID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
    static let siblingBinaryID = UUID(uuidString: "10000000-0000-0000-0000-000000000002")!
    static let selectedFunctionID = UUID(uuidString: "20000000-0000-0000-0000-000000000001")!
    static let secondFunctionID = UUID(uuidString: "20000000-0000-0000-0000-000000000002")!
    static let textStart: UInt64 = 0x1_0000_0000
    static let textSize: UInt64 = 0x2_0000
    static let selectedFunctionStart: UInt64 = textStart + 0x1000
    static let selectedFunctionEnd: UInt64 = selectedFunctionStart + 0x10
    static let siblingFunctionStart: UInt64 = selectedFunctionStart
    static let readableDataStart: UInt64 = textStart + 0x4_0000
    static let readableDataSize: UInt64 = 0x20_0000
    static let selectedSliceByteCount = 0x4000
    static let selectedArtifactUUID = UUID(uuidString: "30000000-0000-0000-0000-000000000001")!
    static let siblingArtifactUUID = UUID(uuidString: "30000000-0000-0000-0000-000000000002")!

    static let defaultSegments: [MachOPreferredSegmentLayout.Record] = [
        segment(
            "__TEXT",
            vmStart: textStart,
            vmSize: textSize,
            fileOffset: 0,
            fileSize: 0x1000,
            protections: 5
        ),
        segment(
            "__DATA",
            vmStart: readableDataStart,
            vmSize: readableDataSize,
            fileOffset: 0x1000,
            fileSize: 0,
            protections: 3
        ),
    ]

    /// Catalog unit cases explicitly root their definitions in the selected signature.
    /// Ordinary snapshots leave unrelated catalog entries out of native admission.
    static func snapshotAdmittingCatalog(
        typeDefinitions: [TypeDefinition]
    ) throws -> WorkspaceSnapshot {
        let parameters = typeDefinitions.enumerated().map { index, definition in
            ArgOverride(
                rowToken: "catalog-\(index)",
                name: "argument_\(index)",
                type: definition.name,
                provenance: .user
            )
        }
        return try snapshot(
            selectedOverrides: [
                selectedFunctionStart: .init(
                    signature: .init(parameterList: .authoritative(parameters))
                ),
            ],
            typeDefinitions: typeDefinitions
        )
    }

    static func function(
        id: UUID = selectedFunctionID,
        name: String = "_selected",
        start: UInt64 = selectedFunctionStart,
        end: UInt64 = selectedFunctionEnd
    ) -> FunctionSummary {
        FunctionSummary(id: id, name: name, startAddress: start, endAddress: end, confidence: 1)
    }

    static func functions(count: Int) -> [FunctionSummary] {
        (0 ..< count).map { index in
            let start = selectedFunctionStart + UInt64(index) * 0x10
            return function(
                id: index == 0 ? selectedFunctionID : stableUUID(group: 0x20, ordinal: index + 1),
                name: "_function_\(index)",
                start: start,
                end: start + 4
            )
        }
    }

    static func instruction(
        address: UInt64,
        bytes: String = "1f 20 03 d5",
        mnemonic: String = "nop"
    ) -> InstructionRow {
        InstructionRow(
            address: address,
            bytes: bytes,
            mnemonic: mnemonic,
            operands: "",
            hasBreakpoint: false,
            comment: nil
        )
    }

    static func symbol(id: Int, name: String, address: UInt64) -> SymbolSummary {
        SymbolSummary(
            id: stableUUID(group: 0x40, ordinal: id),
            name: name,
            address: address,
            kind: "function",
            libraryName: nil,
            rawLinkageName: name
        )
    }

    static func codeDataRange(address: UInt64, size: UInt64, id: Int) -> CodeDataRangeSummary {
        CodeDataRangeSummary(
            id: stableUUID(group: 0x41, ordinal: id),
            address: address,
            size: size,
            kind: "data"
        )
    }

    static func segment(
        _ name: String,
        vmStart: UInt64,
        vmSize: UInt64,
        fileOffset: UInt64,
        fileSize: UInt64,
        protections: Int32
    ) -> MachOPreferredSegmentLayout.Record {
        MachOPreferredSegmentLayout.Record(
            name: name,
            preferredVMStart: vmStart,
            preferredVMSize: vmSize,
            sliceRelativeFileOffset: fileOffset,
            fileSize: fileSize,
            initialProtections: protections
        )
    }

    static func uncheckedPreferredSegmentLayout(
        records: [MachOPreferredSegmentLayout.Record]
    ) -> MachOPreferredSegmentLayout {
        // Durable decoding rejects this malformed authority before construction. The projector
        // still has to fail closed if hostile in-memory state crosses its seam, so this test-only
        // fixture deliberately bypasses the validated initializer for that single proof.
        precondition(
            MemoryLayout<[MachOPreferredSegmentLayout.Record]>.size
                == MemoryLayout<MachOPreferredSegmentLayout>.size
        )
        return unsafeBitCast(records, to: MachOPreferredSegmentLayout.self)
    }

    static func binary(
        id: UUID,
        slot: ImageSlot,
        name: String,
        artifactUUID: UUID,
        bytes: Data,
        preferredSegments: [MachOPreferredSegmentLayout.Record]
    ) throws -> BinaryImage {
        let artifact = try MachOSliceArtifactIdentity(
            uuid: artifactUUID,
            rawCPUType: MachOConstants.cpuTypeARM64,
            rawCPUSubtype: 0,
            selectedSliceSHA256: AnalysisFingerprintBuilder.sha256Hex(bytes),
            selectedSliceByteCount: UInt64(bytes.count)
        )
        let layout = try MachOPreferredSegmentLayout(
            records: preferredSegments,
            selectedSliceByteCount: UInt64(bytes.count)
        )
        return BinaryImage(
            id: id,
            name: name,
            path: "/fixture/\(name)",
            kind: "Mach-O executable",
            architecture: "arm64",
            artifactIdentity: artifact,
            preferredSegmentLayout: layout,
            artifactIntegrityState: .verified,
            slot: slot
        )
    }

    static func snapshot(
        selectedOverrides: [UInt64: AddressOverride] = [:],
        siblingOverrides: [UInt64: AddressOverride] = [:],
        selectedFunctions: [FunctionSummary] = [function()],
        selectedSymbols: [SymbolSummary] = [],
        selectedInstructions: [InstructionRow] = [instruction(address: selectedFunctionStart)],
        selectedCodeDataRanges: [CodeDataRangeSummary] = [],
        preferredSegments: [MachOPreferredSegmentLayout.Record] = defaultSegments,
        siblingFunctions: [FunctionSummary] = [
            function(
                id: secondFunctionID,
                name: "_sibling",
                start: siblingFunctionStart,
                end: siblingFunctionStart + 0x10
            ),
        ],
        typeDefinitions: [TypeDefinition] = []
    ) throws -> WorkspaceSnapshot {
        let selectedBytes = Data(repeating: 0, count: selectedSliceByteCount)
        let siblingBytes = Data(repeating: 0x5a, count: selectedSliceByteCount)
        let selectedBinary = try binary(
            id: selectedBinaryID,
            slot: selectedSlot,
            name: "selected",
            artifactUUID: selectedArtifactUUID,
            bytes: selectedBytes,
            preferredSegments: preferredSegments
        )
        let siblingBinary = try binary(
            id: siblingBinaryID,
            slot: siblingSlot,
            name: "sibling",
            artifactUUID: siblingArtifactUUID,
            bytes: siblingBytes,
            preferredSegments: defaultSegments
        )
        let selectedAnalysis = ImageAnalysis(
            functions: selectedFunctions,
            symbols: selectedSymbols,
            instructions: selectedInstructions,
            codeDataRanges: selectedCodeDataRanges,
            imageBytes: selectedBytes
        )
        let siblingAnalysis = ImageAnalysis(functions: siblingFunctions, imageBytes: siblingBytes)
        var addressOverrides: [ImageAddress: AddressOverride] = [:]
        for (address, value) in selectedOverrides {
            addressOverrides[ImageAddress(slot: selectedSlot, address: address)] = value
        }
        for (address, value) in siblingOverrides {
            addressOverrides[ImageAddress(slot: siblingSlot, address: address)] = value
        }
        return WorkspaceSnapshot(
            binaries: [
                selectedBinary,
                siblingBinary,
            ],
            analysisBySlot: [
                selectedSlot: selectedAnalysis,
                siblingSlot: siblingAnalysis,
            ],
            addressOverrides: addressOverrides,
            typeDefinitions: typeDefinitions
        )
    }

    static func overrides(
        inInsertionOrder entries: [(UInt64, AddressOverride)]
    ) -> [UInt64: AddressOverride] {
        var result: [UInt64: AddressOverride] = [:]
        result.reserveCapacity(entries.count)
        for (address, value) in entries {
            result[address] = value
        }
        return result
    }

    static func field(
        _ name: String,
        _ type: String,
        semantics: FieldDef.DeclaratorSemanticsV1 = .ordinary,
        bitWidth: Int? = nil,
        minimumAlignment: Int? = nil,
        minimumAlignmentType: String? = nil,
        inlineKind: TypeKind? = nil,
        inlineFields: [FieldDef] = [],
        inlineLayout: AggregateLayoutRules = .default,
        promotesInlineFields: Bool = false
    ) -> FieldDef {
        FieldDef(
            name: name,
            type: type,
            declaratorSemanticsV1: semantics,
            bitWidth: bitWidth,
            minimumAlignment: minimumAlignment,
            minimumAlignmentType: minimumAlignmentType,
            inlineAggregateKind: inlineKind,
            inlineFields: inlineFields,
            inlineAggregateLayoutRules: inlineLayout,
            promotesInlineFields: promotesInlineFields
        )
    }

    static func inlineChain(depth: Int) -> FieldDef {
        var field = A4aFixture.field("value", "uint8_t")
        for index in 0 ..< depth {
            field = A4aFixture.field(
                "layer\(index)",
                "ignored-placeholder",
                inlineKind: .struct,
                inlineFields: [field]
            )
        }
        return field
    }

    static func definition(
        _ name: String,
        kind: TypeKind = .struct,
        fields: [FieldDef],
        layout: AggregateLayoutRules = .default,
        id: Int
    ) -> TypeDefinition {
        TypeDefinition(
            id: stableUUID(group: 0x50, ordinal: id),
            kind: kind,
            name: name,
            fields: fields,
            layoutRules: layout
        )
    }

    static func enumCase(_ name: String, _ value: Int64) -> FieldDef {
        field(name, String(value))
    }

    static func stableUUID(group: UInt8, ordinal: Int) -> UUID {
        let suffix = String(format: "%02x%010llx", UInt32(group), UInt64(ordinal))
        return UUID(uuidString: "00000000-0000-0000-0000-\(suffix)")!
    }

    static func nameLengthsForExactCanonicalByteCount(_ target: Int) -> [Int] {
        let base = canonicalFieldByteCount(
            name: "domain",
            valueByteCount: "org.macscope.MacScope.native-authored-input.v1".utf8.count
        )
            + canonicalFieldByteCount(name: "authoredInputs.schemaVersion", valueByteCount: 8)
            + canonicalFieldByteCount(name: "authoredInputs.names.count", valueByteCount: 8)
            + canonicalFieldByteCount(name: "authoredInputs.signatures.count", valueByteCount: 8)
            + canonicalFieldByteCount(name: "authoredInputs.appliedTypes.count", valueByteCount: 8)
            + canonicalFieldByteCount(name: "authoredInputs.typeDefinitions.count", valueByteCount: 8)

        var fullPrefixByteCount = 0
        for count in 2 ... 4_096 {
            let penultimateIndex = count - 2
            let lastIndex = count - 1
            let secondItemSizes = Dictionary(uniqueKeysWithValues: (1 ... 1_023).map { length in
                (canonicalNameItemByteCount(index: lastIndex, nameByteCount: length), length)
            })
            for penultimateLength in 1 ... 1_023 {
                let penultimateSize = canonicalNameItemByteCount(
                    index: penultimateIndex,
                    nameByteCount: penultimateLength
                )
                let needed = target - base - fullPrefixByteCount - penultimateSize
                if let lastLength = secondItemSizes[needed] {
                    return Array(repeating: 1_024, count: count - 2)
                        + [penultimateLength, lastLength]
                }
            }
            fullPrefixByteCount += canonicalNameItemByteCount(
                index: penultimateIndex,
                nameByteCount: 1_024
            )
        }
        return []
    }

    private static func canonicalNameItemByteCount(index: Int, nameByteCount: Int) -> Int {
        let prefix = "authoredInputs.names[\(index)]"
        return canonicalFieldByteCount(name: "\(prefix).address", valueByteCount: 8)
            + canonicalFieldByteCount(name: "\(prefix).subjectKind", valueByteCount: 1)
            + canonicalFieldByteCount(name: "\(prefix).name", valueByteCount: nameByteCount)
    }

    private static func canonicalFieldByteCount(name: String, valueByteCount: Int) -> Int {
        canonicalTokenByteCount(name.utf8.count) + canonicalTokenByteCount(valueByteCount)
    }

    private static func canonicalTokenByteCount(_ payloadByteCount: Int) -> Int {
        String(payloadByteCount).utf8.count + 1 + payloadByteCount + 1
    }
}

private extension Collection {
    var single: Element? {
        count == 1 ? first : nil
    }
}

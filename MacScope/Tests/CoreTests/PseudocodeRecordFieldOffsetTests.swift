import XCTest
@testable import MacScope

/// Byte offsets on actual emitted record-pointer declarations must never
/// accidentally become C record-stride arithmetic. These fixtures carry explicit
/// access widths; ABI-only metadata is intentionally covered separately below.
final class PseudocodeRecordFieldOffsetTests: XCTestCase {
    func testPointerLeafUsedAsRecordBaseKeepsPointerValue() throws {
        let node = TypeDefinition(kind: .struct, name: "Record", fields: [
            FieldDef(name: "tag", type: "uint64_t"),
            FieldDef(name: "next", type: "struct Record *"),
            FieldDef(name: "tail", type: "uint64_t"),
        ])
        let signature = FunctionSignatureOverride.authoritative(returnType: "void", args: [
            ArgOverride(rowToken: "p", name: "p", type: "struct Record *")
        ])
        let rows: [InstructionRow] = [
            .init(address: 0x4000, bytes: "", mnemonic: "ldr", operands: "x8, [x0, #8]", hasBreakpoint: false, comment: nil),
            .init(address: 0x4004, bytes: "", mnemonic: "ldr", operands: "x10, [x8]", hasBreakpoint: false, comment: nil),
            .init(address: 0x4008, bytes: "", mnemonic: "ldr", operands: "x11, [x8, #16]", hasBreakpoint: false, comment: nil),
            .init(address: 0x400c, bytes: "", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil),
        ]
        let text = PseudocodePrinter().print(functionName: "record_chain", startAddress: 0x4000,
            signatureOverrides: [0x4000: signature], types: [node], instructions: rows).text
        let load = try line(in: text, containing: "p->next")
        XCTAssertTrue(load.contains("= p->next;"), text)
        XCTAssertFalse(load.contains("(uint64_t)("), text)
        let destination = try XCTUnwrap(load.components(separatedBy: "=").first)
            .trimmingCharacters(in: .whitespaces)
        XCTAssertFalse(destination.isEmpty, text)
        XCTAssertTrue(text.contains("\(destination)->tag"), text)
        XCTAssertTrue(text.contains("\(destination)->tail"), text)
    }

    func testPointerLeafUsedOnlyAsIntegerKeepsCarrierCast() throws {
        let node = TypeDefinition(kind: .struct, name: "Record", fields: [
            FieldDef(name: "tag", type: "uint64_t"),
            FieldDef(name: "next", type: "struct Record *"),
        ])
        let value = MacIRValue.register(name: "x3", version: 1)
        let text = try render(type: "struct Record *", types: [node], operations: [
            .load(destination: value, address: .binaryExpression(op: "+",
                left: .argument(bindingID: .gpr(0)), right: .immediate(8))),
            .binary(destination: .register(name: "x4", version: 1), op: "&",
                left: value, right: .immediate(1)),
        ], access: .init(byteWidth: 8))
        let load = try line(in: text, containing: "x3_1 =")
        XCTAssertTrue(load.contains("x3_1 = (uint64_t)(p->next);"), text)
        XCTAssertTrue(text.contains("x3_1 & 0x1"), text)
    }

    private var record: TypeDefinition {
        TypeDefinition(kind: .struct, name: "Record", fields: [
            FieldDef(name: "tag", type: "uint32_t"),
            FieldDef(name: "field", type: "uint32_t"),
        ])
    }

    func testExactScalarLeafLoadAndStore() throws {
        let alias = TypeDefinition(kind: .typedef, name: "RecordAlias", fields: [
            FieldDef(name: "", type: "struct Record")
        ])
        let text = try memory(offset: 4, types: [record, alias], type: "RecordAlias *")
        XCTAssertTrue(text.contains("w3_1 = p->field;"), text)
        XCTAssertTrue(text.contains("p->field = w9_0;"), text)
        XCTAssertFalse(text.contains("p + 0x4"), text)
    }

    func testNestedAndArrayLeaves() throws {
        let inner = TypeDefinition(kind: .struct, name: "Inner", fields: [
            FieldDef(name: "tag", type: "uint32_t"),
            FieldDef(name: "field", type: "uint32_t"),
        ])
        let outer = TypeDefinition(kind: .struct, name: "Record", fields: [
            FieldDef(name: "header", type: "uint64_t"),
            FieldDef(name: "nested", type: "struct Inner"),
            FieldDef(name: "array", type: "uint32_t[3]"),
        ])
        let nested = try memory(offset: 12, types: [inner, outer])
        XCTAssertTrue(nested.contains("w3_1 = p->nested.field;"), nested)
        XCTAssertTrue(nested.contains("p->nested.field = w9_0;"), nested)
        let array = try memory(offset: 24, types: [inner, outer])
        XCTAssertTrue(array.contains("w3_1 = p->array[2];"), array)
        XCTAssertTrue(array.contains("p->array[2] = w9_0;"), array)
        // The one-past-array offset is tail padding, not array[3].
        assertByteFallback(try memory(offset: 28, types: [inner, outer]), offset: 28)
    }

    func testNoMatchUnknownAndOutOfBoundsUseByteAddressing() throws {
        for offset: Int64 in [1, 8, 12] {
            assertByteFallback(try memory(offset: offset, types: [record]), offset: offset)
        }
        assertByteFallback(try memory(offset: 4, types: []), offset: 4)
        // A named but incomplete record must not license a guessed member.
        assertByteFallback(try memory(offset: 4, types: [
            TypeDefinition(kind: .struct, name: "Record")
        ]), offset: 4)
    }

    func testAmbiguousAndUnionLayoutsDoNotInventMembers() throws {
        let duplicate = TypeDefinition(kind: .struct, name: "Record", fields: [
            FieldDef(name: "other", type: "uint64_t")
        ])
        assertByteFallback(try memory(offset: 4, types: [record, duplicate]), offset: 4)
        assertByteFallback(try memory(offset: 4, types: [duplicate, record]), offset: 4)
        let union = TypeDefinition(kind: .union, name: "Choice", fields: [
            FieldDef(name: "a", type: "uint32_t"), FieldDef(name: "b", type: "uint32_t")
        ])
        let outer = TypeDefinition(kind: .struct, name: "Record", fields: [
            FieldDef(name: "tag", type: "uint32_t"), FieldDef(name: "choice", type: "union Choice")
        ])
        assertByteFallback(try memory(offset: 4, types: [outer, union]), offset: 4)
        let incomplete = TypeDefinition(kind: .struct, name: "Record", fields: [
            FieldDef(name: "tag", type: "uint32_t"),
            FieldDef(name: "field", type: "uint32_t", layoutIsUnknown: true)
        ])
        assertByteFallback(try memory(offset: 4, types: [incomplete]), offset: 4)
    }

    func testWidthAndExtensionMustMatchLeaf() throws {
        let wrongWidth = try memory(offset: 4, types: [record], width: 8)
        assertByteFallback(wrongWidth, offset: 4, bits: 64)
        let unsignedSignLoad = try memory(offset: 4, types: [record], extensionKind: .sign)
        let load = try line(in: unsignedSignLoad, containing: "x3_1 =")
        XCTAssertFalse(load.contains("p->field"), unsignedSignLoad)
        XCTAssertTrue(load.contains("*(int32_t *)"), unsignedSignLoad)
        XCTAssertTrue(load.contains("(uint8_t *)(p) + 0x4"), unsignedSignLoad)
        let signed = TypeDefinition(kind: .struct, name: "Record", fields: [
            FieldDef(name: "tag", type: "uint32_t"), FieldDef(name: "field", type: "int32_t")
        ])
        let signedZeroLoad = try memory(offset: 4, types: [signed], extensionKind: .zero)
        XCTAssertFalse(try line(in: signedZeroLoad, containing: "x3_1 =").contains("p->field"), signedZeroLoad)
        let signedSignLoad = try memory(offset: 4, types: [signed], extensionKind: .sign)
        XCTAssertTrue(signedSignLoad.contains("x3_1 = p->field;"), signedSignLoad)
    }

    func testPointerLeafDoesNotAcceptScalarStoreOrNarrowAccess() throws {
        let node = TypeDefinition(kind: .struct, name: "Record", fields: [
            FieldDef(name: "tag", type: "uint64_t"), FieldDef(name: "next", type: "struct Record *")
        ])
        let pointer = try memory(offset: 8, types: [node], width: 8)
        XCTAssertTrue(pointer.contains("x3_1 = (uint64_t)(p->next);"), pointer)
        let store = try line(in: pointer, containing: "= x9_0;")
        XCTAssertFalse(store.contains("p->next"), pointer)
        XCTAssertTrue(store.contains("*(uint64_t *)"), pointer)
        XCTAssertTrue(store.contains("(uint8_t *)(p) + 0x8"), pointer)
        assertByteFallback(try memory(offset: 8, types: [node]), offset: 8)
    }

    func testRecordAliasAndCommutedAdditionResolveSameField() throws {
        let alias = TypeDefinition(kind: .typedef, name: "RecordAlias", fields: [
            FieldDef(name: "", type: "struct Record")
        ])
        let text = try memory(offset: 4, types: [record, alias], type: "RecordAlias *", commuted: true)
        XCTAssertTrue(text.contains("w3_1 = p->field;"), text)
        XCTAssertTrue(text.contains("p->field = w9_0;"), text)
    }

    func testGenericAndSubtractedOffsetsRemainByteOffsets() throws {
        for commuted in [false, true] {
            let text = try arithmetic(type: "struct Record *", types: [record], commuted: commuted)
            XCTAssertTrue(text.contains("(struct Record *)((uint8_t *)(p) + 0x4)"), text)
            XCTAssertFalse(text.contains("p->field"), text)
            XCTAssertFalse(text.contains("p + 0x4"), text)
        }
        let subtracted = try memory(offset: 4, types: [record], op: "-")
        XCTAssertFalse(subtracted.contains("p->"), subtracted)
        XCTAssertTrue(subtracted.contains("*(uint32_t *)((uint8_t *)(p) - 0x4)"), subtracted)
    }

    func testSideEffectingBaseAppearsOncePerAccess() throws {
        let base = MacIRValue.unary(op: "(struct Record *)", value: .unknown("next_record()"))
        let text = try memory(offset: 1, types: [record], base: base)
        for marker in ["w3_1 =", "= w9_0;"] {
            let accessLine = try line(in: text, containing: marker)
            XCTAssertEqual(accessLine.components(separatedBy: "next_record()").count - 1, 1, text)
            XCTAssertTrue(accessLine.contains("uint8_t *"), text)
        }
    }

    func testNaturalWidthWithoutDescriptorRetainsScalarFieldAccess() throws {
        let wide = TypeDefinition(kind: .struct, name: "Record", fields: [
            FieldDef(name: "tag", type: "uint64_t"), FieldDef(name: "field64", type: "uint64_t")
        ])
        let address = MacIRValue.binaryExpression(op: "+", left: .argument(bindingID: .gpr(0)),
                                                   right: .immediate(8))
        let text = try render(type: "struct Record *", types: [wide], operations: [
            .load(destination: .register(name: "x3", version: 1), address: address),
            .store(source: .register(name: "x9", version: 0), address: address),
        ])
        XCTAssertTrue(text.contains("x3_1 = p->field64;"), text)
        XCTAssertTrue(text.contains("p->field64 = x9_0;"), text)
    }

    func testBooleanStorePreservesRawByteRatherThanConvertingToBoolean() throws {
        let flag = TypeDefinition(kind: .struct, name: "Record", fields: [
            FieldDef(name: "tag", type: "uint32_t"), FieldDef(name: "flag", type: "_Bool")
        ])
        let text = try memory(offset: 4, types: [flag], width: 1)
        let store = try line(in: text, containing: "= w9_0;")
        XCTAssertFalse(store.contains("p->flag"), text)
        XCTAssertTrue(store.contains("*(uint8_t *)"), text)
        XCTAssertTrue(store.contains("(uint8_t *)(p) + 0x4"), text)
    }

    func testInvalidAndDuplicateMemberNamesRefuseSugar() throws {
        for fields in [
            [FieldDef(name: "tag", type: "uint32_t"), FieldDef(name: "not-a-member", type: "uint32_t")],
            [FieldDef(name: "tag", type: "uint32_t"), FieldDef(name: "return", type: "uint32_t")],
            [FieldDef(name: "field", type: "uint32_t"), FieldDef(name: "field", type: "uint32_t")],
        ] {
            let invalid = TypeDefinition(kind: .struct, name: "Record", fields: fields)
            assertByteFallback(try memory(offset: 4, types: [invalid]), offset: 4)
        }
    }

    func testArrayOfRecordsEmitsCompleteLeafPath() throws {
        let inner = TypeDefinition(kind: .struct, name: "Inner", fields: [
            FieldDef(name: "tag", type: "uint32_t"), FieldDef(name: "field", type: "uint32_t")
        ])
        let outer = TypeDefinition(kind: .struct, name: "Record", fields: [
            FieldDef(name: "header", type: "uint64_t"), FieldDef(name: "items", type: "struct Inner[3]")
        ])
        let text = try memory(offset: 28, types: [inner, outer])
        XCTAssertTrue(text.contains("w3_1 = p->items[2].field;"), text)
        XCTAssertTrue(text.contains("p->items[2].field = w9_0;"), text)
    }

    func testDuplicateWholePointerAliasesRefuseInEitherCatalogOrder() throws {
        let first = TypeDefinition(kind: .typedef, name: "RecordPointer", fields: [
            FieldDef(name: "", type: "struct Record *")
        ])
        let second = TypeDefinition(kind: .typedef, name: "RecordPointer", fields: [
            FieldDef(name: "", type: "uint32_t *")
        ])
        for aliases in [[first, second], [second, first]] {
            let text = try memory(offset: 4, types: [record] + aliases, type: "RecordPointer")
            assertByteFallback(text, offset: 4)
        }
    }

    func testPromotedAnonymousUnionRefusesUniqueOffsetLeaf() throws {
        let inner = TypeDefinition(kind: .struct, name: "Inner", fields: [
            FieldDef(name: "first", type: "uint32_t"), FieldDef(name: "second", type: "uint32_t")
        ])
        let outer = TypeDefinition(kind: .struct, name: "Record", fields: [
            FieldDef(name: "tag", type: "uint64_t"),
            FieldDef(name: "", type: "union", inlineAggregateKind: .union, inlineFields: [
                FieldDef(name: "small", type: "uint32_t"),
                FieldDef(name: "wide", type: "struct Inner")
            ], promotesInlineFields: true)
        ])
        // Only wide.second occupies offset 12, but reaching it still selects a union arm.
        assertByteFallback(try memory(offset: 12, types: [inner, outer]), offset: 12)
    }

    func testMismatchedFloatingStoreAndUnknownLoadCarrierRefuseField() throws {
        let floating = TypeDefinition(kind: .struct, name: "Record", fields: [
            FieldDef(name: "tag", type: "uint32_t"), FieldDef(name: "field", type: "float")
        ])
        let address = MacIRValue.binaryExpression(op: "+", left: .argument(bindingID: .gpr(0)),
                                                   right: .immediate(4))
        let store = try render(type: "struct Record *", types: [floating], operations: [
            .store(source: .register(name: "d9", version: 0), address: address)
        ], access: .init(byteWidth: 4))
        XCTAssertFalse(store.contains("p->field"), store)
        XCTAssertTrue(store.contains("*(uint32_t *)((uint8_t *)(p) + 0x4) = (uint32_t)(__bitcast_u64(d9_0));"), store)
        let load = try render(type: "struct Record *", types: [record], operations: [
            .load(destination: .register(name: "unsupported", version: 1), address: address)
        ], access: .init(byteWidth: 4))
        assertByteFallback(load, offset: 4)
    }

    func testSignedIntegerStorePreservesBitsWithoutSignedConversion() throws {
        let signed = TypeDefinition(kind: .struct, name: "Record", fields: [
            FieldDef(name: "tag", type: "uint32_t"), FieldDef(name: "field", type: "int32_t")
        ])
        let text = try memory(offset: 4, types: [signed])
        let store = try line(in: text, containing: "= w9_0;")
        XCTAssertFalse(store.contains("p->field ="), text)
        XCTAssertTrue(store.contains("*(uint32_t *)((uint8_t *)(p) + 0x4)"), text)
    }

    func testBooleanRawLoadDoesNotNormalizeStoredByte() throws {
        let flag = TypeDefinition(kind: .struct, name: "Record", fields: [
            FieldDef(name: "tag", type: "uint32_t"), FieldDef(name: "flag", type: "_Bool")
        ])
        let text = try memory(offset: 4, types: [flag], width: 1, extensionKind: .zero)
        let load = try line(in: text, containing: "x3_1 =")
        XCTAssertFalse(load.contains("p->flag"), text)
        XCTAssertTrue(load.contains("*(uint8_t *)((uint8_t *)(p) + 0x4)"), text)
    }

    func testConstRootAndConstFieldStoresDoNotAssignMembers() throws {
        let constField = TypeDefinition(kind: .struct, name: "Record", fields: [
            FieldDef(name: "tag", type: "uint32_t"), FieldDef(name: "field", type: "const uint32_t")
        ])
        for (type, definition) in [("const struct Record *", record), ("struct Record *", constField)] {
            let text = try memory(offset: 4, types: [definition], type: type)
            let store = try line(in: text, containing: "= w9_0;")
            XCTAssertFalse(store.contains("p->field"), text)
            XCTAssertTrue(store.contains("uint32_t *"), text)
            XCTAssertTrue(store.contains("uint8_t *"), text)
        }
    }

    func testBarePointerStackSlotStillLoadsAndStoresTheSlot() throws {
        let source = MacIRSourceSpan(address: 0x5000, byteText: "", mnemonic: "fixture", operands: "")
        let operations: [MacIROperation] = [
            .load(destination: .register(name: "x3", version: 1), address: .stackSlot(offset: 8)),
            .store(source: .register(name: "x9", version: 0), address: .stackSlot(offset: 8)),
        ]
        let function = MacIRFunction(name: "pointer_slot", startAddress: 0x5000,
            localVariables: [MacIRLocalVariable(offset: 8, name: "savedRecord",
                                               type: "struct Record *", byteWidth: 8)],
            instructions: operations.map {
                MacIRInstruction(source: source, operation: $0, memoryAccess: .init(byteWidth: 8))
            })
        let text = PseudocodePrinter().print(function: function, types: [record]).text
        XCTAssertTrue(text.contains("x3_1 = savedRecord;"), text)
        XCTAssertTrue(text.contains("savedRecord = x9_0;"), text)
        XCTAssertFalse(text.contains("savedRecord->"), text)
        XCTAssertFalse(text.contains("*(savedRecord)"), text)
        XCTAssertFalse(text.contains("(uint8_t *)(savedRecord)"), text)
    }

    func testUnknownWidthTemporaryLoadUsesExplicitIntrinsic() throws {
        let address = MacIRValue.binaryExpression(op: "+", left: .argument(bindingID: .gpr(0)),
                                                   right: .immediate(4))
        let text = try render(type: "struct Record *", types: [record], operations: [
            .load(destination: .temporary(0), address: address)
        ])
        XCTAssertTrue(text.contains("tmp_0 = __load_unknown_width((uint8_t *)(p) + 0x4);"), text)
        XCTAssertFalse(text.contains("p->field"), text)
    }

    func testUnknownWidthTemporaryStoreUsesExplicitIntrinsic() throws {
        let address = MacIRValue.binaryExpression(op: "+", left: .argument(bindingID: .gpr(0)),
                                                   right: .immediate(4))
        let text = try render(type: "struct Record *", types: [record], operations: [
            .store(source: .temporary(0), address: address)
        ])
        XCTAssertTrue(text.contains("__store_unknown_width((uint8_t *)(p) + 0x4, tmp_0);"), text)
        XCTAssertFalse(text.contains("p->field"), text)
    }

    func testExplicitWidthTemporaryUsesSizedFallbackWithoutFieldProof() throws {
        let address = MacIRValue.binaryExpression(op: "+", left: .argument(bindingID: .gpr(0)),
                                                   right: .immediate(4))
        let text = try render(type: "struct Record *", types: [record], operations: [
            .load(destination: .temporary(0), address: address),
            .store(source: .temporary(0), address: address)
        ], access: .init(byteWidth: 4))
        XCTAssertTrue(text.contains("tmp_0 = *(uint32_t *)((uint8_t *)(p) + 0x4);"), text)
        XCTAssertTrue(text.contains("*(uint32_t *)((uint8_t *)(p) + 0x4) = tmp_0;"), text)
        XCTAssertFalse(text.contains("p->field"), text)
        XCTAssertFalse(text.contains("unknown_width"), text)
    }

    func testMultidimensionalArrayUsesRowMajorIndices() throws {
        let matrix = TypeDefinition(kind: .struct, name: "Record", fields: [
            FieldDef(name: "header", type: "uint64_t"), FieldDef(name: "matrix", type: "uint32_t[2][3]")
        ])
        let text = try memory(offset: 28, types: [matrix])
        XCTAssertTrue(text.contains("w3_1 = p->matrix[1][2];"), text)
        XCTAssertTrue(text.contains("p->matrix[1][2] = w9_0;"), text)
    }

    func testNestedByteOffsetFallbackDoesNotReintroduceRecordStride() throws {
        let inner = MacIRValue.binaryExpression(op: "+", left: .argument(bindingID: .gpr(0)),
                                                right: .immediate(1))
        let text = try memory(offset: 1, types: [record], base: inner)
        for marker in ["w3_1 =", "= w9_0;"] {
            let accessLine = try line(in: text, containing: marker)
            XCTAssertTrue(accessLine.contains("uint8_t *"), text)
            XCTAssertTrue(accessLine.contains("uint32_t *"), text)
            XCTAssertFalse(accessLine.contains("struct Record *"), text)
            XCTAssertFalse(accessLine.contains("p->"), text)
            XCTAssertFalse(accessLine.contains("p + 0x"), text)
        }
    }

    func testVectorRegisterScalarStoresDoNotClaimScalarMember() throws {
        let address = MacIRValue.binaryExpression(op: "+", left: .argument(bindingID: .gpr(0)),
                                                   right: .immediate(4))
        for carrier in ["q9", "v9"] {
            let text = try render(type: "struct Record *", types: [record], operations: [
                .store(source: .register(name: carrier, version: 0), address: address)
            ], access: .init(byteWidth: 4))
            assertByteFallback(text, offset: 4)
        }
    }

    func testConstTypedefStoreDoesNotAssignMember() throws {
        let alias = TypeDefinition(kind: .typedef, name: "ReadOnlyWord", fields: [
            FieldDef(name: "", type: "const uint32_t")
        ])
        let qualified = TypeDefinition(kind: .struct, name: "Record", fields: [
            FieldDef(name: "tag", type: "uint32_t"), FieldDef(name: "field", type: "ReadOnlyWord")
        ])
        let text = try memory(offset: 4, types: [qualified, alias])
        let store = try line(in: text, containing: "= w9_0;")
        XCTAssertFalse(store.contains("p->field"), text)
        XCTAssertTrue(store.contains("*(uint32_t *)"), text)
        XCTAssertTrue(store.contains("uint8_t *"), text)
    }

    func testNaturalWidthWritebackUsesSizedMemoryAndByteUpdate() throws {
        let base = MacIRValue.argument(bindingID: .gpr(0))
        for preIndex in [false, true] {
            let operations: [MacIROperation] = [
                .loadWriteback(destination: .register(name: "w3", version: 1),
                    baseDestination: .register(name: "x0", version: 1), baseSource: base,
                    delta: 4, preIndex: preIndex),
                .storeWriteback(source: .register(name: "w9", version: 0),
                    baseDestination: .register(name: "x0", version: 2), baseSource: base,
                    delta: 4, preIndex: preIndex),
            ]
            let text = try render(type: "struct Record *", types: [record], operations: operations)
            for marker in ["w3_1", "w9_0"] {
                let accessLine = try line(in: text, containing: marker)
                XCTAssertTrue(accessLine.contains("*(uint32_t *)"), text)
                XCTAssertTrue(accessLine.contains("(struct Record *)((uint8_t *)(p) + 0x4)"), text)
                XCTAssertFalse(accessLine.contains("p->"), text)
                XCTAssertFalse(accessLine.contains("p + 0x4"), text)
            }
        }
    }

    func testVolatilePointeeFallbackKeepsVolatileOnMemoryAccess() throws {
        let text = try memory(offset: 1, types: [record], type: "volatile struct Record *")
        let expected = "*(volatile uint32_t *)((volatile uint8_t *)(p) + 0x1)"
        XCTAssertTrue(try line(in: text, containing: "w3_1 =").contains(expected), text)
        XCTAssertTrue(try line(in: text, containing: "= w9_0;").contains(expected), text)
        XCTAssertFalse(text.contains("p->"), text)
    }

    func testTopLevelConstPointerStillAllowsPointeeFieldStore() throws {
        let pointerConst = try memory(offset: 4, types: [record], type: "struct Record * const")
        XCTAssertTrue(pointerConst.contains("p->field = w9_0;"), pointerConst)
        let pointeeConst = try memory(offset: 4, types: [record], type: "const struct Record *")
        XCTAssertFalse(try line(in: pointeeConst, containing: "= w9_0;").contains("p->field"), pointeeConst)
    }

    func testPointerTypedefQualificationStaysAtCorrectIndirection() throws {
        let pointer = TypeDefinition(kind: .typedef, name: "Ptr", fields: [
            FieldDef(name: "", type: "struct Record *")
        ])
        let readOnly = TypeDefinition(kind: .typedef, name: "PtrToConst", fields: [
            FieldDef(name: "", type: "const struct Record *")
        ])
        let types = [record, pointer, readOnly]
        let pointerConst = try memory(offset: 4, types: types, type: "const Ptr")
        XCTAssertTrue(pointerConst.contains("p->field = w9_0;"), pointerConst)
        let pointeeConst = try memory(offset: 4, types: types, type: "PtrToConst")
        let store = try line(in: pointeeConst, containing: "= w9_0;")
        XCTAssertFalse(store.contains("p->field"), pointeeConst)
        XCTAssertTrue(store.contains("uint32_t *"), pointeeConst)
        XCTAssertTrue(store.contains("uint8_t *"), pointeeConst)
        XCTAssertFalse(store.contains("unknown_width"), pointeeConst)
    }

    func testLiteralStoreWithoutDescriptorRetainsKnownNaturalWidth() throws {
        let address = MacIRValue.binaryExpression(op: "+", left: .argument(bindingID: .gpr(0)),
                                                   right: .immediate(1))
        let text = try render(type: "struct Record *", types: [record], operations: [
            .store(source: .immediate(7), address: address)
        ])
        XCTAssertTrue(text.contains("*(uint64_t *)((uint8_t *)(p) + 0x1) = 0x7;"), text)
        XCTAssertFalse(text.contains("unknown_width"), text)
    }

    func testExplicitCastStoreWithoutDescriptorRetainsKnownWidth() throws {
        let address = MacIRValue.binaryExpression(op: "+", left: .argument(bindingID: .gpr(0)),
                                                   right: .immediate(1))
        let text = try render(type: "struct Record *", types: [record], operations: [
            .store(source: .unary(op: "(uint32_t)", value: .temporary(0)), address: address)
        ])
        XCTAssertTrue(text.contains("*(uint32_t *)((uint8_t *)(p) + 0x1)"), text)
        XCTAssertFalse(text.contains("unknown_width"), text)
    }

    func testTypedArgumentStoreWithoutDescriptorRetainsValidatedABIWidth() throws {
        let pointer = try XCTUnwrap(MacIRFunctionParameter(
            id: .init(rawValue: "auth:p"), bindingID: .gpr(0), sourcePosition: 0,
            abiLocation: .gpr(index: 0, carrierWidth: 64), type: "struct Record *", name: "p",
            evidence: .authoritativeUser))
        let value = try XCTUnwrap(MacIRFunctionParameter(
            id: .init(rawValue: "auth:value"), bindingID: .gpr(1), sourcePosition: 1,
            abiLocation: .gpr(index: 1, carrierWidth: 32), type: "uint32_t", name: "value",
            evidence: .authoritativeUser))
        let address = MacIRValue.binaryExpression(op: "+", left: .argument(bindingID: .gpr(0)),
                                                   right: .immediate(1))
        let instruction = MacIRInstruction(
            source: .init(address: 0x6000, byteText: "", mnemonic: "fixture", operands: ""),
            operation: .store(source: .argument(bindingID: .gpr(1)), address: address))
        let function = MacIRFunction(name: "typed_argument_store", startAddress: 0x6000,
            parameters: [pointer, value], instructions: [instruction])
        let text = PseudocodePrinter().print(function: function, types: [record]).text
        XCTAssertTrue(text.contains("*(uint32_t *)((uint8_t *)(p) + 0x1) = value;"), text)
        XCTAssertFalse(text.contains("unknown_width"), text)
    }

    func testNaturalWidthStackFloatStoreRetainsFloatingMemoryType() throws {
        let pointer = try XCTUnwrap(MacIRFunctionParameter(
            id: .init(rawValue: "auth:p"), bindingID: .gpr(0), sourcePosition: 0,
            abiLocation: .gpr(index: 0, carrierWidth: 64), type: "struct Record *", name: "p",
            evidence: .authoritativeUser))
        let stackFloat = try XCTUnwrap(MacIRFunctionParameter(
            id: .init(rawValue: "auth:stackFloat"), bindingID: .entryStack(byteOffset: 0), sourcePosition: 1,
            abiLocation: .entryStack(byteOffset: 0, size: 4, alignment: 4), type: "float", name: "savedFloat",
            evidence: .authoritativeUser))
        let address = MacIRValue.binaryExpression(op: "+", left: .argument(bindingID: .gpr(0)),
                                                   right: .immediate(1))
        let instruction = MacIRInstruction(
            source: .init(address: 0x7000, byteText: "", mnemonic: "fixture", operands: ""),
            operation: .store(source: .argument(bindingID: .entryStack(byteOffset: 0)), address: address))
        let function = MacIRFunction(name: "stack_float_store", startAddress: 0x7000,
            parameters: [pointer, stackFloat], instructions: [instruction])
        let text = PseudocodePrinter().print(function: function, types: [record]).text
        XCTAssertTrue(text.contains("*(float *)((uint8_t *)(p) + 0x1) = savedFloat;"), text)
        XCTAssertFalse(text.contains("unknown_width"), text)
    }

    func testNaturalWidthHalfCarrierRetainsHalfPrecisionMemoryType() throws {
        let address = MacIRValue.binaryExpression(op: "+", left: .argument(bindingID: .gpr(0)),
                                                   right: .immediate(1))
        let text = try render(type: "struct Record *", types: [record], operations: [
            .load(destination: .register(name: "h3", version: 1), address: address),
            .store(source: .register(name: "h9", version: 0), address: address)
        ])
        XCTAssertTrue(text.contains("h3_1 = *(_Float16 *)((uint8_t *)(p) + 0x1);"), text)
        XCTAssertTrue(text.contains("*(_Float16 *)((uint8_t *)(p) + 0x1) = h9_0;"), text)
        XCTAssertFalse(text.contains("unknown_width"), text)
    }

    func testExplicitWidthPointerSourceStoreConvertsToIntegerRepresentation() throws {
        let address = MacIRValue.binaryExpression(op: "+", left: .argument(bindingID: .gpr(0)),
                                                   right: .immediate(1))
        let text = try render(type: "struct Record *", types: [record], operations: [
            .store(source: .argument(bindingID: .gpr(0)), address: address)
        ], access: .init(byteWidth: 8))
        XCTAssertTrue(text.contains("*(uint64_t *)((uint8_t *)(p) + 0x1) = (uint64_t)(p);"), text)
        XCTAssertFalse(text.contains("p->"), text)
    }

    func testNestedVolatileStorageRetainsVolatileFallbackDereference() throws {
        let volatileInner = TypeDefinition(kind: .struct, name: "Inner", fields: [
            FieldDef(name: "value", type: "volatile uint32_t")
        ])
        let union = TypeDefinition(kind: .union, name: "Choice", fields: [
            FieldDef(name: "raw", type: "uint32_t"), FieldDef(name: "observed", type: "volatile uint32_t")
        ])
        let alternatives = [
            FieldDef(name: "items", type: "struct Inner[2]"),
            FieldDef(name: "choice", type: "union Choice"),
            FieldDef(name: "inlineValue", type: "struct", inlineAggregateKind: .struct, inlineFields: [
                FieldDef(name: "observed", type: "volatile uint32_t")
            ])
        ]
        for member in alternatives {
            let outer = TypeDefinition(kind: .struct, name: "Record", fields: [member])
            let text = try memory(offset: 1, types: [outer, volatileInner, union])
            for marker in ["w3_1 =", "= w9_0;"] {
                let accessLine = try line(in: text, containing: marker)
                XCTAssertTrue(accessLine.contains("*(volatile uint32_t *)"), text)
                XCTAssertFalse(accessLine.contains("p->"), text)
            }
        }
    }

    func testBareVolatileRootUnknownWidthRetainsQualifiedAddress() throws {
        let base = MacIRValue.argument(bindingID: .gpr(0))
        let text = try render(type: "volatile struct Record *", types: [record], operations: [
            .load(destination: .temporary(0), address: base),
            .store(source: .temporary(0), address: base)
        ])
        XCTAssertTrue(text.contains("tmp_0 = __load_unknown_width((volatile uint8_t *)(p));"), text)
        XCTAssertTrue(text.contains("__store_unknown_width((volatile uint8_t *)(p), tmp_0);"), text)
    }

    func testNaturalWidthRegisterAliasesNeverBecomeUnknownWidth() throws {
        let address = MacIRValue.binaryExpression(op: "+", left: .argument(bindingID: .gpr(0)),
                                                   right: .immediate(1))
        for (name, bits) in [("xzr", 64), ("wzr", 32), ("fp", 64), ("lr", 64),
                             ("sp", 64), ("wsp", 64), ("FP", 64)] {
            let text = try render(type: "struct Record *", types: [record], operations: [
                .load(destination: .register(name: name, version: 1), address: address),
                .store(source: .register(name: name, version: 0), address: address)
            ])
            XCTAssertTrue(text.contains("*(uint\(bits)_t *)((uint8_t *)(p) + 0x1)"), text)
            XCTAssertFalse(text.contains("unknown_width"), text)
        }
    }

    func testUppercaseFloatingCarriersPreserveNaturalWidthAndClass() throws {
        let address = MacIRValue.binaryExpression(op: "+", left: .argument(bindingID: .gpr(0)),
                                                   right: .immediate(1))
        for (name, type) in [("H9", "_Float16"), ("S9", "float"), ("D9", "double")] {
            let text = try render(type: "struct Record *", types: [record], operations: [
                .load(destination: .register(name: name, version: 1), address: address),
                .store(source: .register(name: name, version: 0), address: address)
            ])
            XCTAssertTrue(text.contains("*(\(type) *)((uint8_t *)(p) + 0x1)"), text)
            XCTAssertFalse(text.contains("unknown_width"), text)
        }
    }

    func testNamedInlineStructEmitsCompleteNestedFieldPath() throws {
        let outer = TypeDefinition(kind: .struct, name: "Record", fields: [
            FieldDef(name: "header", type: "uint64_t"),
            FieldDef(name: "nested", type: "struct", inlineAggregateKind: .struct, inlineFields: [
                FieldDef(name: "tag", type: "uint32_t"),
                FieldDef(name: "field", type: "uint32_t")
            ], inlineAggregateLayoutRules: .default)
        ])
        let text = try memory(offset: 12, types: [outer])
        XCTAssertTrue(text.contains("w3_1 = p->nested.field;"), text)
        XCTAssertTrue(text.contains("p->nested.field = w9_0;"), text)
    }

    func testSizedPairAndWritebackStoresConvertPointerSourcesOnlyAtRecordMemory() throws {
        let pointer = MacIRValue.argument(bindingID: .gpr(0))
        let baseDestination = MacIRValue.register(name: "x2", version: 1)
        let cases: [(MacIROperation, Int)] = [
            (.storeWriteback(source: pointer, baseDestination: baseDestination,
                             baseSource: pointer, delta: 8, preIndex: true), 1),
            (.intrinsic(destination: nil, name: "save_pair", arguments: [pointer, pointer, pointer]), 2),
            (.intrinsic(destination: nil, name: "save_pair_writeback", arguments: [
                pointer, pointer, pointer, baseDestination, .immediate(16), .immediate(1)
            ]), 2),
        ]
        for (operation, count) in cases {
            let text = try render(type: "struct Record *", types: [record], operations: [operation],
                                  access: .init(byteWidth: 8))
            XCTAssertEqual(text.components(separatedBy: "(uint64_t)(p)").count - 1, count, text)
            XCTAssertTrue(text.contains("*(uint64_t *)"), text)
            XCTAssertFalse(text.contains("p->"), text)
        }
        let ordinaryAddress = MacIRValue.unary(op: "(uint64_t *)", value: .temporary(1))
        let ordinary = try render(type: "struct Record *", types: [record], operations: [
            .intrinsic(destination: nil, name: "save_pair", arguments: [pointer, pointer, ordinaryAddress])
        ], access: .init(byteWidth: 8))
        XCTAssertFalse(ordinary.contains("(uint64_t)(p)"), ordinary)
    }

    func testDoubleCarrierWordAccessPreservesBitsRatherThanNumericallyConverting() throws {
        // Execute the same IR transfer contract: double 1.0 stores its low word,
        // while a word load into d3 zero-extends raw bits rather than converting.
        let stored = try evaluateWordAccess(carrier: "d9", isStore: true,
                                           vectorBits: 0x3ff0000000000000, memoryBits: 0xffffffff)
        XCTAssertEqual((0..<4).map { stored.byte(at: 0x500084 + UInt64($0)) }, [0, 0, 0, 0])
        let loaded = try evaluateWordAccess(carrier: "d3", isStore: false,
                                           vectorBits: UInt64.max, memoryBits: 0x3f800000)
        XCTAssertEqual(loaded.v[3].low, 0x000000003f800000)
        let address = MacIRValue.binaryExpression(op: "+", left: .argument(bindingID: .gpr(0)),
                                                   right: .immediate(4))
        let text = try render(type: "struct Record *", types: [record], operations: [
            .store(source: .register(name: "d9", version: 0), address: address),
            .load(destination: .register(name: "d3", version: 1), address: address)
        ], access: .init(byteWidth: 4))
        XCTAssertTrue(text.contains("*(uint32_t *)((uint8_t *)(p) + 0x4) = (uint32_t)(__bitcast_u64(d9_0));"), text)
        XCTAssertTrue(text.contains("d3_1 = __bitcast_f64((uint64_t)(*(uint32_t *)((uint8_t *)(p) + 0x4)));"), text)
        XCTAssertFalse(text.contains("*(float *)"), text)
        XCTAssertFalse(text.contains("p->field"), text)
    }

    func testSinglePrecisionCarrierWidthChangesUseIntegerBitBridge() throws {
        let address = MacIRValue.binaryExpression(op: "+", left: .argument(bindingID: .gpr(0)),
                                                   right: .immediate(1))
        for width in [2, 8] {
            let text = try render(type: "struct Record *", types: [record], operations: [
                .store(source: .register(name: "s9", version: 0), address: address),
                .load(destination: .register(name: "s3", version: 1), address: address)
            ], access: .init(byteWidth: width))
            let integer = "uint\(width * 8)_t"
            XCTAssertTrue(text.contains("*(\(integer) *)((uint8_t *)(p) + 0x1) = (\(integer))(__bitcast_u32(s9_0));"), text)
            XCTAssertTrue(text.contains("s3_1 = __bitcast_f32((uint32_t)(*(\(integer) *)((uint8_t *)(p) + 0x1)));"), text)
            XCTAssertFalse(text.contains("p->"), text)
        }
    }

    func testMismatchedDoublePairAndWritebackStoresKeepRawMemoryLvalues() throws {
        let pointer = MacIRValue.argument(bindingID: .gpr(0))
        let source = MacIRValue.register(name: "d9", version: 0)
        let baseDestination = MacIRValue.register(name: "x2", version: 1)
        let cases: [(MacIROperation, Int)] = [
            (.storeWriteback(source: source, baseDestination: baseDestination,
                             baseSource: pointer, delta: 4, preIndex: true), 1),
            (.intrinsic(destination: nil, name: "save_pair", arguments: [source, source, pointer]), 2),
            (.intrinsic(destination: nil, name: "save_pair_writeback", arguments: [
                source, source, pointer, baseDestination, .immediate(8), .immediate(1)
            ]), 2),
        ]
        for (operation, count) in cases {
            let text = try render(type: "struct Record *", types: [record], operations: [operation],
                                  access: .init(byteWidth: 4))
            let store = try line(in: text, containing: "__bitcast_u64(d9_0)")
            let sides = store.components(separatedBy: " = ")
            XCTAssertEqual(sides.count, 2, text)
            let lhs = try XCTUnwrap(sides.first)
            XCTAssertEqual(lhs.components(separatedBy: "*(uint32_t *)").count - 1, count, text)
            XCTAssertFalse(lhs.contains("__bitcast_"), text)
            XCTAssertFalse(lhs.contains("*(float *)"), text)
            XCTAssertEqual(store.components(separatedBy: "(uint32_t)(__bitcast_u64(d9_0))").count - 1, count, text)
            XCTAssertFalse(store.contains("p->"), text)
        }
    }

    func testHalfCarrierWordStoreMatchesConcreteLowBits() throws {
        let state = try evaluateWordAccess(carrier: "h9", isStore: true,
                                          vectorBits: 0x3c00, memoryBits: 0xffffffff)
        XCTAssertEqual((0..<4).map { state.byte(at: 0x500084 + UInt64($0)) }, [0x00, 0x3c, 0x00, 0x00])
        let address = MacIRValue.binaryExpression(op: "+", left: .argument(bindingID: .gpr(0)),
                                                   right: .immediate(4))
        let text = try render(type: "struct Record *", types: [record], operations: [
            .store(source: .register(name: "h9", version: 0), address: address)
        ], access: .init(byteWidth: 4))
        XCTAssertTrue(text.contains("*(uint32_t *)((uint8_t *)(p) + 0x4) = (uint32_t)(__bitcast_u16(h9_0));"), text)
        XCTAssertFalse(text.contains("*(float *)"), text)
    }

    func testHalfCarrierWordLoadMatchesConcreteTruncation() throws {
        let state = try evaluateWordAccess(carrier: "h3", isStore: false,
                                          vectorBits: UInt64.max, memoryBits: 0x12343c00)
        XCTAssertEqual(state.v[3].low, 0x3c00)
        let address = MacIRValue.binaryExpression(op: "+", left: .argument(bindingID: .gpr(0)),
                                                   right: .immediate(4))
        let text = try render(type: "struct Record *", types: [record], operations: [
            .load(destination: .register(name: "h3", version: 1), address: address)
        ], access: .init(byteWidth: 4))
        XCTAssertTrue(text.contains("h3_1 = __bitcast_f16((uint16_t)(*(uint32_t *)((uint8_t *)(p) + 0x4)));"), text)
        XCTAssertFalse(text.contains("*(float *)"), text)
    }

    private func evaluateWordAccess(carrier: String, isStore: Bool, vectorBits: UInt64,
                                    memoryBits: UInt32) throws -> A64MachineState {
        let pointer = try XCTUnwrap(MacIRFunctionParameter(
            id: .init(rawValue: "auth:p"), bindingID: .gpr(0), sourcePosition: 0,
            abiLocation: .gpr(index: 0, carrierWidth: 64), type: "struct Record *", name: "p",
            evidence: .authoritativeUser))
        let address = MacIRValue.binaryExpression(op: "+", left: .argument(bindingID: .gpr(0)),
                                                   right: .immediate(4))
        let value = MacIRValue.register(name: carrier, version: isStore ? 0 : 1)
        let instruction = MacIRInstruction(
            source: .init(address: 0x4000, byteText: "", mnemonic: "fixture", operands: ""),
            operation: isStore ? .store(source: value, address: address) : .load(destination: value, address: address),
            memoryAccess: .init(byteWidth: 4))
        let function = MacIRFunction(name: "record_word_witness", startAddress: 0x4000,
                                     parameters: [pointer], instructions: [instruction])
        var state = try A64MachineState(seeding: JSONDecoder().decode(A64OracleVector.State.self,
                                                                    from: Data("{}".utf8)))
        state.x[0] = 0x500080
        let vectorIndex = try XCTUnwrap(Int(carrier.dropFirst()))
        state.v[vectorIndex].low = vectorBits
        for byte in 0..<4 {
            state.setByte(UInt8(truncatingIfNeeded: memoryBits >> (byte * 8)), at: 0x500084 + UInt64(byte))
        }
        var evaluator = MacIRConcreteEvaluator(function: function, state: state)
        try evaluator.run(function.instructions)
        return evaluator.state
    }

    func testMismatchedDoublePairAndWritebackLoadsUseBitwiseReads() throws {
        let pointer = MacIRValue.argument(bindingID: .gpr(0))
        let first = MacIRValue.register(name: "d3", version: 1)
        let second = MacIRValue.register(name: "d4", version: 1)
        let baseDestination = MacIRValue.register(name: "x2", version: 1)
        let cases: [(MacIROperation, Int, Int)] = [
            (.intrinsic(destination: nil, name: "restore_pair", arguments: [first, second, pointer]), 2, 0),
            (.intrinsic(destination: nil, name: "restore_pair_writeback", arguments: [
                first, second, pointer, baseDestination, .immediate(4), .immediate(1)
            ]), 2, 1),
            (.loadWriteback(destination: first, baseDestination: baseDestination,
                            baseSource: pointer, delta: 4, preIndex: true), 1, 1),
        ]
        for (operation, reads, updates) in cases {
            let text = try render(type: "struct Record *", types: [record], operations: [operation],
                                  access: .init(byteWidth: 4))
            let accessLine = try XCTUnwrap(text.components(separatedBy: "\n").first {
                $0.contains("d3_1") && $0.contains(" = ")
            })
            XCTAssertEqual(accessLine.components(separatedBy: "__bitcast_f64((uint64_t)(*(uint32_t *)").count - 1,
                           reads, text)
            XCTAssertEqual(accessLine.components(separatedBy: "(struct Record *)").count - 1, updates, text)
            XCTAssertTrue(accessLine.contains("(uint8_t *)(p) + 0x4"), text)
            XCTAssertFalse(accessLine.contains("p + 0x4"), text)
            XCTAssertFalse(accessLine.contains("p->"), text)
            if updates == 0 {
                XCTAssertTrue(accessLine.contains("*(uint32_t *)((uint8_t *)(p))"), text)
            }
            if reads == 2 && updates == 1 {
                XCTAssertTrue(accessLine.contains("*(uint32_t *)(((uint8_t *)(p) + 0x4) + 0x4)"), text)
            }
        }
    }

    func testNaturalWidthExpressionStoresUseStaticallyProvenShape() throws {
        let w = MacIRValue.register(name: "w9", version: 0)
        let x = MacIRValue.register(name: "x10", version: 0)
        let s = MacIRValue.register(name: "s9", version: 0)
        let d = MacIRValue.register(name: "d10", version: 0)
        let byte = MacIRValue.unary(op: "(uint8_t)", value: .temporary(0))
        let cases: [(MacIRValue, String)] = [
            (.unary(op: "-", value: byte), "uint32_t"),
            (.unary(op: "~", value: byte), "uint32_t"),
            (.binaryExpression(op: "+", left: w, right: w), "uint32_t"),
            (.binaryExpression(op: "+", left: w, right: x), "uint64_t"),
            (.binaryExpression(op: "+", left: s, right: s), "float"),
            (.binaryExpression(op: "+", left: s, right: d), "double"),
            (.binaryExpression(op: "==", left: x, right: x), "uint32_t"),
            (.binaryExpression(op: "&&", left: x, right: x), "uint32_t"),
            (.binaryExpression(op: "<<", left: w, right: x), "uint32_t"),
        ]
        let address = MacIRValue.binaryExpression(op: "+", left: .argument(bindingID: .gpr(0)),
                                                   right: .immediate(1))
        for (value, type) in cases {
            let text = try render(type: "struct Record *", types: [record], operations: [
                .store(source: value, address: address)
            ])
            XCTAssertTrue(text.contains("*(\(type) *)((uint8_t *)(p) + 0x1)"), text)
            XCTAssertFalse(text.contains("unknown_width"), text)
            XCTAssertFalse(text.contains("p->"), text)
        }
    }

    func testIncompleteRootScalarPrefixAcrossPointerToArrayLayoutCarrier() throws {
        let partial = TypeDefinition(kind: .struct, name: "Record", fields: [
            FieldDef(name: "head", type: "uint32_t"),
            FieldDef(name: "carrier", type: "int32_t *", declaratorSemanticsV1: .pointerToArrayCarrier),
            FieldDef(name: "after", type: "uint32_t"),
            FieldDef(name: "tail", type: "MissingTail")
        ])
        for (offset, field) in [(Int64(0), "head"), (Int64(16), "after")] {
            let text = try memory(offset: offset, types: [partial])
            XCTAssertTrue(text.contains("w3_1 = p->\(field);"), text)
            XCTAssertTrue(text.contains("p->\(field) = w9_0;"), text)
        }
    }

    func testIncompleteRootPointerToArrayTargetRefusesField() throws {
        let partial = TypeDefinition(kind: .struct, name: "Record", fields: [
            FieldDef(name: "head", type: "uint32_t"),
            FieldDef(name: "carrier", type: "int32_t *", declaratorSemanticsV1: .pointerToArrayCarrier),
            FieldDef(name: "after", type: "uint32_t"),
            FieldDef(name: "tail", type: "MissingTail")
        ])
        let text = try memory(offset: 8, types: [partial], width: 8)
        assertByteFallback(text, offset: 8, bits: 64)
        XCTAssertTrue(text.contains("x3_1 = *(uint64_t *)((uint8_t *)(p) + 0x8);"), text)
        XCTAssertTrue(text.contains("*(uint64_t *)((uint8_t *)(p) + 0x8) = x9_0;"), text)
        XCTAssertFalse(text.contains("p->carrier"), text)
    }

    func testIncompleteRootUnprovedNonTargetCarrierRefusesPrefix() throws {
        let predecessors = [
            FieldDef(name: "poison", type: "MissingPredecessor", declaratorSemanticsV1: .pointerToArrayCarrier),
            FieldDef(name: "poison", type: "MissingPredecessor"),
            FieldDef(name: "poison", type: "uint32_t", layoutIsUnknown: true)
        ]
        for predecessor in predecessors {
            let partial = TypeDefinition(kind: .struct, name: "Record", fields: [
                FieldDef(name: "first", type: "uint32_t"), predecessor,
                FieldDef(name: "after", type: "uint32_t"),
                FieldDef(name: "tail", type: "MissingTail")
            ])
            // Eight is a machine displacement, not a proved offset for after.
            let text = try memory(offset: 8, types: [partial])
            assertByteFallback(text, offset: 8)
            XCTAssertTrue(text.contains("w3_1 = *(uint32_t *)((uint8_t *)(p) + 0x8);"), text)
            XCTAssertTrue(text.contains("*(uint32_t *)((uint8_t *)(p) + 0x8) = w9_0;"), text)
            XCTAssertFalse(text.contains("p->after"), text)
        }
    }

    func testScalarAndPointerToPointerArithmeticControls() throws {
        XCTAssertTrue(try arithmetic(type: "uint16_t *").contains("x2_1 = p + 0x2;"))
        let pointers = try arithmetic(type: "struct Record **", bytes: 8)
        XCTAssertTrue(pointers.contains("x2_1 = p + 0x1;"), pointers)
        XCTAssertFalse(pointers.contains("uint8_t *"), pointers)
    }

    func testABIOnlyRecordMetadataRetainsLegacyArithmetic() throws {
        let text = try arithmetic(type: "struct Record *", types: [record], sourcePosition: nil)
        XCTAssertTrue(text.contains("x2_1 = p + 0x4;"), text)
        XCTAssertFalse(text.contains("(uint8_t *)(p)"), text)
    }

    private func assertByteFallback(_ text: String, offset: Int64, bits: Int = 32,
                                    file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(text.contains("p->"), text, file: file, line: line)
        XCTAssertTrue(text.contains("*(uint\(bits)_t *)"), text, file: file, line: line)
        XCTAssertTrue(text.contains("*(uint\(bits)_t *)((uint8_t *)(p) + 0x\(String(offset, radix: 16)))"),
                      text, file: file, line: line)
        XCTAssertFalse(text.contains("p + 0x"), text, file: file, line: line)
    }

    private func line(in text: String, containing marker: String) throws -> String {
        try XCTUnwrap(text.components(separatedBy: "\n").first { $0.contains(marker) })
    }

    private func memory(offset: Int64, types: [TypeDefinition], type: String = "struct Record *",
                        width: Int = 4, extensionKind: MacIRMemoryAccess.ExtensionKind = .none,
                        op: String = "+", commuted: Bool = false, base: MacIRValue? = nil) throws -> String {
        let p = base ?? .argument(bindingID: .gpr(0))
        let address = MacIRValue.binaryExpression(op: op,
            left: commuted ? .immediate(offset) : p, right: commuted ? p : .immediate(offset))
        let loadRegister = width == 8 || extensionKind != .none ? "x3" : "w3"
        let storeRegister = width == 8 ? "x9" : "w9"
        return try render(type: type, types: types, operations: [
            .load(destination: .register(name: loadRegister, version: 1), address: address),
            .store(source: .register(name: storeRegister, version: 0), address: address),
        ], access: .init(byteWidth: width, extensionKind: extensionKind))
    }

    private func arithmetic(type: String, types: [TypeDefinition] = [], bytes: Int64 = 4,
                            commuted: Bool = false, sourcePosition: Int? = 0) throws -> String {
        let p = MacIRValue.argument(bindingID: .gpr(0))
        return try render(type: type, types: types, sourcePosition: sourcePosition, operations: [
            .binary(destination: .register(name: "x2", version: 1), op: "+",
                    left: commuted ? .immediate(bytes) : p, right: commuted ? p : .immediate(bytes))
        ])
    }

    private func render(type: String, types: [TypeDefinition], sourcePosition: Int? = 0,
                        operations: [MacIROperation], access: MacIRMemoryAccess? = nil) throws -> String {
        let parameter = try XCTUnwrap(MacIRFunctionParameter(
            id: .init(rawValue: "auth:p"), bindingID: .gpr(0), sourcePosition: sourcePosition,
            abiLocation: .gpr(index: 0, carrierWidth: 64), type: type, name: "p",
            evidence: .authoritativeUser))
        let function = MacIRFunction(name: "record_offset", startAddress: 0x4000,
            parameters: [parameter], instructions: operations.enumerated().map { index, operation in
                MacIRInstruction(source: .init(address: 0x4000 + UInt64(index * 4), byteText: "",
                                              mnemonic: "fixture", operands: ""),
                                 operation: operation, memoryAccess: access)
            })
        return PseudocodePrinter().print(function: function, types: types).text
    }
}

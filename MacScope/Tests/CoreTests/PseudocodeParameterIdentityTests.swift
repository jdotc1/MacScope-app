import XCTest
@testable import MacScope

/// WS-14 printer contract: source-formal order, physical ABI location, and
/// stable body binding are independent namespaces.
final class PseudocodeParameterIdentityTests: XCTestCase {
    func testAuthoritativeMixedPlanIsInstalledBeforeLiftAndUsesIndependentBanks() throws {
        let scale = parameter(
            id: "auth:scale",
            bindingID: .simd(0),
            sourcePosition: 0,
            location: .simd(index: 0, scalarWidth: 64),
            type: "double",
            name: "scale"
        )
        let values = parameter(
            id: "auth:values",
            bindingID: .gpr(0),
            sourcePosition: 1,
            location: .gpr(index: 0, carrierWidth: 64),
            type: "int *",
            name: "values"
        )
        let plan = try XCTUnwrap(MacIRAuthoritativeParameterPlan(
            parameters: [scale, values],
            isVariadic: false
        ))
        let rows = [
            row(0x1000, "fmov", "x3, d0"),
            row(0x1004, "ldr", "w2, [x0]"),
            row(0x1008, "ret", ""),
        ]

        let function = MacIRBuilder().buildFunction(
            name: "_mixed_authoritative",
            authoritativeParameterPlan: plan,
            instructions: rows
        )

        XCTAssertEqual(function.parameters.map(\.sourcePosition), [0, 1])
        XCTAssertEqual(function.parameters.map(\.bindingID), [.simd(0), .gpr(0)])
        guard case let .intrinsic(_, name, arguments) = function.instructions[0].operation else {
            return XCTFail("expected the existing FP-to-GPR bit move lift")
        }
        XCTAssertEqual(name, "fmov")
        XCTAssertEqual(arguments, [.argument(bindingID: .simd(0))])
        guard case let .load(_, pointer) = function.instructions[1].operation else {
            return XCTFail("expected ldr to lift as a load")
        }
        XCTAssertEqual(pointer, .argument(bindingID: .gpr(0)))

        let document = PseudocodePrinter().print(function: function)
        XCTAssertEqual(
            try signatureLine(in: document).text,
            "int64_t _mixed_authoritative(double scale, int * values) {"
        )
        XCTAssertTrue(document.text.contains("x3_1 = __fmov(scale);"), document.text)
        XCTAssertTrue(document.text.contains("w2_1 = *(uint32_t *)(values);"), document.text)
    }

    func testOrdinaryDeclarationSortsBySourcePositionNotArrayOrBindingOrder() throws {
        let pointer = parameter(
            id: "auth:pointer",
            bindingID: .gpr(0),
            sourcePosition: 1,
            location: .gpr(index: 0, carrierWidth: 64),
            type: "int *",
            name: "pointer"
        )
        let amount = parameter(
            id: "auth:amount",
            bindingID: .simd(0),
            sourcePosition: 0,
            location: .simd(index: 0, scalarWidth: 64),
            type: "double",
            name: "amount"
        )
        let function = manualFunction(
            name: "_source_order",
            parameters: [pointer, amount],
            operation: .returnValue(.argument(bindingID: .simd(0)))
        )

        let document = PseudocodePrinter().print(function: function)

        XCTAssertEqual(
            try signatureLine(in: document).text,
            "int64_t _source_order(double amount, int * pointer) {"
        )
        XCTAssertTrue(document.text.contains("return amount;"), document.text)
    }

    func testSparseRecoveredInputRendersAsABICommentRatherThanFalsePrototype() throws {
        let function = MacIRBuilder().buildFunction(
            name: "_sparse",
            instructions: [
                row(0x1100, "mov", "x2, x1"),
                row(0x1104, "ret", ""),
            ]
        )

        let document = PseudocodePrinter().print(function: function)

        XCTAssertEqual(
            try signatureLine(in: document).text,
            "int64_t _sparse(/* ABI inputs: x1:int64_t in_x1 */) {"
        )
        XCTAssertTrue(document.text.contains("x2_1 = in_x1;"), document.text)
        XCTAssertFalse(document.text.contains("int64_t in_x1)"), document.text)
    }

    func testMixedRecoveredBanksRenderAsABICommentWithoutInventingSourceOrder() throws {
        let function = MacIRBuilder().buildFunction(
            name: "_mixed_recovered",
            instructions: [
                row(0x1200, "mov", "x2, x0"),
                row(0x1204, "fmov", "x3, d0"),
                row(0x1208, "ret", ""),
            ]
        )

        let document = PseudocodePrinter().print(function: function)

        XCTAssertEqual(
            try signatureLine(in: document).text,
            "int64_t _mixed_recovered(/* ABI inputs: x0:int64_t in_x0, d0:double in_d0 */) {"
        )
        XCTAssertTrue(document.text.contains("x2_1 = in_x0;"), document.text)
        XCTAssertTrue(document.text.contains("x3_1 = __fmov(in_d0);"), document.text)
    }

    func testABIOnlyNamesPreserveExactRegisterViewInSignatureAndBody() throws {
        let fixtures: [(String, MacIRParameterBindingID, MacIRABIParameterLocation, String)] = [
            ("w1", .gpr(1), .gpr(index: 1, carrierWidth: 32), "int32_t"),
            ("x1", .gpr(1), .gpr(index: 1, carrierWidth: 64), "int64_t"),
            ("s0", .simd(0), .simd(index: 0, scalarWidth: 32), "float"),
            ("d0", .simd(0), .simd(index: 0, scalarWidth: 64), "double"),
        ]

        for (view, bindingID, location, type) in fixtures {
            let input = parameter(
                id: "recovered:\(view)",
                bindingID: bindingID,
                sourcePosition: nil,
                location: location,
                type: type,
                name: "in_\(view)",
                evidence: .heuristicEntryRead
            )
            let function = manualFunction(
                name: "_view_\(view)",
                parameters: [input],
                operation: .returnValue(.argument(bindingID: bindingID))
            )

            let document = PseudocodePrinter().print(function: function)

            XCTAssertEqual(
                try signatureLine(in: document).text,
                "int64_t _view_\(view)(/* ABI inputs: \(view):\(type) in_\(view) */) {"
            )
            XCTAssertTrue(document.text.contains("return in_\(view);"), document.text)
        }
    }

    func testABIInputRegionIsOneBlockCommentToken() throws {
        let input = parameter(
            id: "recovered:x1",
            bindingID: .gpr(1),
            sourcePosition: nil,
            location: .gpr(index: 1, carrierWidth: 64),
            type: "int64_t",
            name: "in_x1",
            evidence: .heuristicEntryRead
        )
        let document = PseudocodePrinter().print(function: manualFunction(
            name: "_tokenized",
            parameters: [input],
            operation: .returnValue(.argument(bindingID: .gpr(1)))
        ))
        let signature = try signatureLine(in: document)

        let comments = signature.tokens.filter { $0.kind == .comment }
        XCTAssertEqual(comments.map(\.text), ["/* ABI inputs: x1:int64_t in_x1 */"])
        let comment = try XCTUnwrap(comments.first)
        let characters = Array(signature.text)
        XCTAssertEqual(String(characters[comment.range]), comment.text)
    }

    func testUnclosedBlockCommentConsumesRemainderAsOneCommentToken() throws {
        let malformedName = parameter(
            id: "auth:malformed-name",
            bindingID: .gpr(0),
            sourcePosition: 0,
            location: .gpr(index: 0, carrierWidth: 64),
            type: "int64_t",
            name: "value /* incomplete"
        )
        let document = PseudocodePrinter().print(function: manualFunction(
            name: "_unclosed_comment",
            parameters: [malformedName],
            operation: .returnValue(.argument(bindingID: .gpr(0)))
        ))
        let signature = try signatureLine(in: document)

        XCTAssertEqual(
            signature.tokens.filter { $0.kind == .comment }.map(\.text),
            ["/* incomplete) {"]
        )
    }

    func testDuplicateBindingMetadataKeepsDeclarationsButBodyFallsBack() throws {
        let left = parameter(
            id: "auth:left",
            bindingID: .gpr(0),
            sourcePosition: 0,
            location: .gpr(index: 0, carrierWidth: 64),
            type: "int64_t",
            name: "left"
        )
        let right = parameter(
            id: "auth:right",
            bindingID: .gpr(0),
            sourcePosition: 1,
            location: .gpr(index: 0, carrierWidth: 64),
            type: "uint64_t",
            name: "right"
        )
        let function = manualFunction(
            name: "_duplicate_binding",
            parameters: [right, left],
            operation: .returnValue(.argument(bindingID: .gpr(0)))
        )

        let document = PseudocodePrinter().print(function: function)

        XCTAssertEqual(
            try signatureLine(in: document).text,
            "int64_t _duplicate_binding(int64_t left, uint64_t right) {"
        )
        XCTAssertTrue(document.text.contains("return in_x0;"), document.text)
        XCTAssertFalse(document.text.contains("return left;"), document.text)
        XCTAssertFalse(document.text.contains("return right;"), document.text)
    }

    func testDanglingBodyBindingUsesDeterministicPlaceholder() throws {
        let function = manualFunction(
            name: "_dangling_binding",
            parameters: [],
            operation: .returnValue(.argument(bindingID: .gpr(1)))
        )

        let document = PseudocodePrinter().print(function: function)

        XCTAssertEqual(try signatureLine(in: document).text, "int64_t _dangling_binding(void) {")
        XCTAssertTrue(document.text.contains("return in_x1;"), document.text)
    }

    func testStructPointerSugarResolvesTypeByBindingRatherThanSourcePosition() throws {
        let scale = parameter(
            id: "auth:scale",
            bindingID: .simd(0),
            sourcePosition: 0,
            location: .simd(index: 0, scalarWidth: 64),
            type: "double",
            name: "scale"
        )
        let foo = parameter(
            id: "auth:foo",
            bindingID: .gpr(0),
            sourcePosition: 1,
            location: .gpr(index: 0, carrierWidth: 64),
            type: "struct Foo *",
            name: "foo"
        )
        let fooType = TypeDefinition(kind: .struct, name: "Foo", fields: [
            FieldDef(name: "first", type: "int64_t"),
            FieldDef(name: "second", type: "int64_t"),
        ])
        let function = manualFunction(
            name: "_field_by_binding",
            parameters: [foo, scale],
            operation: .load(
                destination: .register(name: "x2", version: 1),
                address: .binaryExpression(
                    op: "+",
                    left: .argument(bindingID: .gpr(0)),
                    right: .immediate(8)
                )
            )
        )

        let document = PseudocodePrinter().print(function: function, types: [fooType])

        XCTAssertEqual(
            try signatureLine(in: document).text,
            "int64_t _field_by_binding(double scale, struct Foo * foo) {"
        )
        XCTAssertTrue(document.text.contains("x2_1 = foo->second;"), document.text)
        XCTAssertFalse(document.text.contains("+ 0x8"), document.text)
    }

    func testQualifiedStructPointerSugarUsesTheStrictSharedPointerGrammar() throws {
        let foo = parameter(
            id: "auth:qualified-foo",
            bindingID: .gpr(0),
            sourcePosition: 0,
            location: .gpr(index: 0, carrierWidth: 64),
            type: "const struct Foo * const",
            name: "foo"
        )
        let fooType = TypeDefinition(kind: .struct, name: "Foo", fields: [
            FieldDef(name: "first", type: "int64_t"),
            FieldDef(name: "second", type: "int64_t"),
        ])
        let function = manualFunction(
            name: "_qualified_field",
            parameters: [foo],
            operation: .load(
                destination: .register(name: "x2", version: 1),
                address: .binaryExpression(
                    op: "+",
                    left: .argument(bindingID: .gpr(0)),
                    right: .immediate(8)
                )
            )
        )

        let document = PseudocodePrinter().print(function: function, types: [fooType])

        XCTAssertTrue(document.text.contains("x2_1 = foo->second;"), document.text)
        XCTAssertFalse(document.text.contains("+ 0x8"), document.text)
    }

    func testPointerToPointerDoesNotBecomeStructFieldSugar() throws {
        let foo = parameter(
            id: "auth:foo-pointer-pointer",
            bindingID: .gpr(0),
            sourcePosition: 0,
            location: .gpr(index: 0, carrierWidth: 64),
            type: "struct Foo **",
            name: "foo"
        )
        let fooType = TypeDefinition(kind: .struct, name: "Foo", fields: [
            FieldDef(name: "first", type: "int64_t"),
            FieldDef(name: "second", type: "int64_t"),
        ])
        let function = manualFunction(
            name: "_pointer_pointer",
            parameters: [foo],
            operation: .load(
                destination: .register(name: "x2", version: 1),
                address: .binaryExpression(
                    op: "+",
                    left: .argument(bindingID: .gpr(0)),
                    right: .immediate(8)
                )
            )
        )

        let document = PseudocodePrinter().print(function: function, types: [fooType])

        XCTAssertTrue(document.text.contains("+ 0x1"), document.text)
        XCTAssertFalse(document.text.contains("foo->second"), document.text)
    }

    func testPersistedRowProvenanceMapsToAuthoritativeEvidence() throws {
        let cases: [(ArgOverride.Provenance, MacIRParameterEvidence)] = [
            (.debug, .authoritativeDebug),
            (.user, .authoritativeUser),
            (.script, .authoritativeUser),
            // A safely migrated/adopted legacy row is authoritative source order;
            // ambiguous legacy rows never enter an active parameter list.
            (.legacy, .authoritativeUser),
        ]

        for (offset, testCase) in cases.enumerated() {
            let address = UInt64(0x2400 + offset * 0x20)
            let row = ArgOverride(
                rowToken: "provenance-\(offset)",
                name: "value",
                type: "int64_t",
                provenance: testCase.0
            )
            let signature = FunctionSignatureOverride(
                parameterList: .authoritative([row]),
                variadicState: .fixed
            )

            let document = PseudocodePrinter().print(
                functionName: "_provenance_\(offset)",
                startAddress: address,
                signatureOverrides: [address: signature],
                instructions: [
                    self.row(address, "mov", "x1, x0"),
                    self.row(address + 4, "ret", ""),
                ]
            )

            XCTAssertEqual(document.parameters.map(\.evidence), [testCase.1])
        }
    }

    func testVariadicWithoutNamedRowsDoesNotRenderAsFixedVoid() throws {
        let function = manualFunction(
            name: "_variadic_only",
            parameters: [],
            isVariadic: true,
            operation: .returnValue(.immediate(0))
        )

        XCTAssertEqual(
            try signatureLine(in: PseudocodePrinter().print(function: function)).text,
            "int64_t _variadic_only(...) {"
        )
    }

    func testABIOnlyVariadicInputsKeepBothPhysicalEvidenceAndEllipsis() throws {
        let input = parameter(
            id: "recovered:x1:variadic",
            bindingID: .gpr(1),
            sourcePosition: nil,
            location: .gpr(index: 1, carrierWidth: 64),
            type: "int64_t",
            name: "in_x1",
            evidence: .heuristicEntryRead
        )
        let function = manualFunction(
            name: "_abi_variadic",
            parameters: [input],
            isVariadic: true,
            operation: .returnValue(.argument(bindingID: .gpr(1)))
        )

        XCTAssertEqual(
            try signatureLine(in: PseudocodePrinter().print(function: function)).text,
            "int64_t _abi_variadic(... /* ABI inputs: x1:int64_t in_x1 */) {"
        )
    }

    func testUnspecifiedPlanRecoversInputsWhileExplicitEmptyPlanMeansVoid() throws {
        let rows = [
            row(0x1300, "mov", "x2, x1"),
            row(0x1304, "ret", ""),
        ]
        let unspecified = MacIRBuilder().buildFunction(name: "_unspecified", instructions: rows)
        let explicitVoidPlan = try XCTUnwrap(MacIRAuthoritativeParameterPlan(
            parameters: [],
            isVariadic: false
        ))
        let explicitVoid = MacIRBuilder().buildFunction(
            name: "_explicit_void",
            authoritativeParameterPlan: explicitVoidPlan,
            instructions: rows
        )

        XCTAssertEqual(unspecified.parameters.map(\.bindingID), [.gpr(1)])
        XCTAssertTrue(explicitVoid.parameters.isEmpty)
        XCTAssertEqual(
            try signatureLine(in: PseudocodePrinter().print(function: unspecified)).text,
            "int64_t _unspecified(/* ABI inputs: x1:int64_t in_x1 */) {"
        )
        XCTAssertEqual(
            try signatureLine(in: PseudocodePrinter().print(function: explicitVoid)).text,
            "int64_t _explicit_void(void) {"
        )
    }

    private func parameter(
        id: String,
        bindingID: MacIRParameterBindingID?,
        sourcePosition: Int?,
        location: MacIRABIParameterLocation,
        type: String,
        name: String,
        evidence: MacIRParameterEvidence = .authoritativeUser
    ) -> MacIRFunctionParameter {
        guard let parameter = MacIRFunctionParameter(
            id: .init(rawValue: id),
            bindingID: bindingID,
            sourcePosition: sourcePosition,
            abiLocation: location,
            type: type,
            name: name,
            evidence: evidence
        ) else {
            preconditionFailure("invalid parameter fixture \(id)")
        }
        return parameter
    }

    private func manualFunction(
        name: String,
        parameters: [MacIRFunctionParameter],
        isVariadic: Bool = false,
        operation: MacIROperation
    ) -> MacIRFunction {
        MacIRFunction(
            name: name,
            startAddress: 0x2000,
            isVariadic: isVariadic,
            parameters: parameters,
            instructions: [
                MacIRInstruction(
                    source: MacIRSourceSpan(
                        address: 0x2000,
                        byteText: "",
                        mnemonic: "fixture",
                        operands: ""
                    ),
                    operation: operation
                ),
            ]
        )
    }

    private func signatureLine(in document: PseudocodeDocument) throws -> PseudocodeLine {
        try XCTUnwrap(document.lines.first { $0.kind == .signature })
    }

    private func row(_ address: UInt64, _ mnemonic: String, _ operands: String) -> InstructionRow {
        InstructionRow(
            address: address,
            bytes: "",
            mnemonic: mnemonic,
            operands: operands,
            hasBreakpoint: false,
            comment: nil
        )
    }
}

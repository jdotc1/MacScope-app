import XCTest
@testable import MacScope

/// WS-14 Phase A4: body argument values carry only a proven ABI binding.
/// Presentation metadata belongs to the owning function's parameter table and
/// must never become part of MacIR value identity.
final class MacIRParameterBindingValueTests: XCTestCase {
    func testArgumentBindingKeepsGPRAndSIMDSlotZeroDistinct() {
        XCTAssertNotEqual(
            MacIRValue.argument(bindingID: .gpr(0)),
            MacIRValue.argument(bindingID: .simd(0))
        )
    }

    func testArgumentIdentityDoesNotIncludeNameTypeOrSourcePosition() throws {
        let value = MacIRValue.argument(bindingID: .gpr(0))
        let original = makeParameter(
            rowID: "row:original",
            bindingID: .gpr(0),
            sourcePosition: 0,
            abiLocation: .gpr(index: 0, carrierWidth: 64),
            type: "int64_t",
            name: "original"
        )
        let overridden = makeParameter(
            rowID: "row:overridden",
            bindingID: .gpr(0),
            sourcePosition: 4,
            abiLocation: .gpr(index: 0, carrierWidth: 32),
            type: "uint32_t",
            name: "overridden"
        )

        let originalDocument = render(returning: value, parameters: [original])
        let overriddenDocument = render(returning: value, parameters: [overridden])

        XCTAssertEqual(value, MacIRValue.argument(bindingID: .gpr(0)))
        XCTAssertEqual(try returnLine(in: originalDocument), "    return original; // return")
        XCTAssertEqual(try returnLine(in: overriddenDocument), "    return overridden; // return")
    }

    func testMissingMetadataUsesOnlyBindingDerivedPlaceholders() throws {
        let cases: [(MacIRParameterBindingID, String)] = [
            (.gpr(0), "in_x0"),
            (.simd(0), "in_d0"),
            (.entryStack(byteOffset: 16), "in_stack_16"),
        ]

        for (bindingID, placeholder) in cases {
            let document = render(
                returning: .argument(bindingID: bindingID),
                parameters: []
            )
            XCTAssertEqual(
                try returnLine(in: document),
                "    return \(placeholder); // return",
                "a dangling body binding must not manufacture source metadata"
            )
        }
    }

    func testDuplicateParameterBindingFailsClosedInsteadOfChoosingMetadata() throws {
        let first = makeParameter(
            rowID: "row:first",
            bindingID: .gpr(0),
            sourcePosition: 0,
            abiLocation: .gpr(index: 0, carrierWidth: 64),
            type: "FirstType",
            name: "firstName"
        )
        let second = makeParameter(
            rowID: "row:second",
            bindingID: .gpr(0),
            sourcePosition: 1,
            abiLocation: .gpr(index: 0, carrierWidth: 32),
            type: "SecondType",
            name: "secondName"
        )

        let document = render(
            returning: .argument(bindingID: .gpr(0)),
            parameters: [first, second]
        )
        let renderedReturn = try returnLine(in: document)

        XCTAssertEqual(renderedReturn, "    return in_x0; // return")
        XCTAssertFalse(renderedReturn.contains("firstName"))
        XCTAssertFalse(renderedReturn.contains("secondName"))
    }

    func testLocalAndPostCallValuesAreNotIncomingArguments() {
        let incoming = MacIRValue.argument(bindingID: .gpr(0))
        let local = MacIRValue.stackSlot(offset: -16)
        let indirectTarget = MacIRValue.register(name: "x16", version: 0)
        let authenticationModifier = MacIRValue.register(name: "x17", version: 0)
        let postCallResult = MacIRValue.register(name: "x0", version: 1)
        let observationScope = MacIRCallArgumentObservationScope(gprIndices: [0])!
        let arguments = MacIRCallArguments(
            [
                MacIRCallArgument(
                    location: .gpr(index: 0, carrierWidth: 64),
                    role: .unknown,
                    value: incoming
                ),
            ],
            observationScope: observationScope
        )!
        let controlInputs = MacIRCallControlInputs([
            MacIRCallControlInput(
                role: .indirectTarget,
                register: .gpr(index: 16),
                value: indirectTarget
            ),
            MacIRCallControlInput(
                role: .pointerAuthenticationModifier,
                register: .gpr(index: 17),
                value: authenticationModifier
            ),
        ])!
        let frame = MacIRCallFrame(
            target: "(*x16)",
            knownSignature: nil,
            controlInputs: controlInputs,
            arguments: arguments
        )!
        let operation = MacIROperation.call(
            frame: frame,
            result: postCallResult
        )

        XCTAssertNotEqual(local, incoming)
        XCTAssertNotEqual(postCallResult, incoming)

        guard case let .call(frame, result) = operation else {
            return XCTFail("expected call operation")
        }
        XCTAssertEqual(frame.target, "(*x16)")
        XCTAssertEqual(
            frame.bindingValues,
            [indirectTarget, authenticationModifier, incoming],
            "call bindings must preserve target, modifier, then physical-argument order"
        )
        XCTAssertEqual(
            frame.bindingValues + [result].compactMap { $0 },
            [indirectTarget, authenticationModifier, incoming, postCallResult],
            "operation traversal must append the call result after every input binding"
        )
        XCTAssertEqual(frame.arguments.denseUnknownGPRPrefixValues(), [incoming])
        XCTAssertEqual(result, postCallResult)
        XCTAssertNotEqual(result, Optional(incoming))
    }

    func testArgumentCaseCarriesOnlyTheTypedBindingPayload() {
        let value = MacIRValue.argument(bindingID: .simd(3))

        guard case let .argument(bindingID) = value else {
            return XCTFail("expected argument value")
        }
        XCTAssertEqual(bindingID, .simd(3))
        XCTAssertEqual(value.description, "in_d3")
    }

    private func makeParameter(
        rowID: String,
        bindingID: MacIRParameterBindingID,
        sourcePosition: Int?,
        abiLocation: MacIRABIParameterLocation,
        type: String,
        name: String
    ) -> MacIRFunctionParameter {
        guard let parameter = MacIRFunctionParameter(
            id: .init(rawValue: rowID),
            bindingID: bindingID,
            sourcePosition: sourcePosition,
            abiLocation: abiLocation,
            type: type,
            name: name,
            evidence: .authoritativeUser
        ) else {
            preconditionFailure("test fixture has a binding/location mismatch")
        }
        return parameter
    }

    private func render(
        returning value: MacIRValue,
        parameters: [MacIRFunctionParameter]
    ) -> PseudocodeDocument {
        let source = MacIRSourceSpan(
            address: 0x1000,
            byteText: "c0 03 5f d6",
            mnemonic: "ret",
            operands: ""
        )
        let function = MacIRFunction(
            name: "binding_value",
            startAddress: source.address,
            parameters: parameters,
            returnValue: value,
            instructions: [
                MacIRInstruction(source: source, operation: .returnValue(value)),
            ]
        )
        return PseudocodePrinter().print(function: function)
    }

    private func returnLine(in document: PseudocodeDocument) throws -> String {
        try XCTUnwrap(document.lines.first(where: { $0.text.contains("return ") })?.text)
    }
}

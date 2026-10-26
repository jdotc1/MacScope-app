import XCTest
@testable import MacScope

/// WS-14 Phase A: parameter body identity, ABI location, and source order are
/// three independent namespaces. These tests intentionally exercise only the
/// additive model seam; lifting and rendering migrate in Phase B.
final class MacIRParameterIdentityModelTests: XCTestCase {
    func testGPRAndSIMDSlotZeroAreDistinctBodyBindings() {
        XCTAssertNotEqual(MacIRParameterBindingID.gpr(0), .simd(0))
        XCTAssertEqual(Set([MacIRParameterBindingID.gpr(0), .simd(0)]).count, 2)
    }

    func testWidthViewsProjectToOneBankQualifiedBinding() {
        XCTAssertEqual(
            MacIRABIParameterLocation.gpr(index: 3, carrierWidth: 32).bindingID,
            .gpr(3)
        )
        XCTAssertEqual(
            MacIRABIParameterLocation.gpr(index: 3, carrierWidth: 64).bindingID,
            .gpr(3)
        )
        XCTAssertEqual(
            MacIRABIParameterLocation.simd(index: 3, scalarWidth: 32).bindingID,
            .simd(3)
        )
        XCTAssertEqual(
            MacIRABIParameterLocation.simd(index: 3, scalarWidth: 64).bindingID,
            .simd(3)
        )
    }

    func testEntryStackUsesByteOffsetAndUnboundHasNoBinding() {
        let stackLocation = MacIRABIParameterLocation.entryStack(byteOffset: 1, size: 1, alignment: 1)
        XCTAssertEqual(stackLocation.bindingID, .entryStack(byteOffset: 1))
        let declarationOnly = MacIRFunctionParameter(
            id: .init(rawValue: "row:stack-declaration"),
            bindingID: nil,
            sourcePosition: 8,
            abiLocation: stackLocation,
            type: "char",
            name: "ninth",
            evidence: .authoritativeUser
        )!
        XCTAssertNil(declarationOnly.bindingID, "ABI location alone must not fabricate a body binding")
        XCTAssertNil(
            MacIRABIParameterLocation.unbound(reason: .unsupportedType("struct Big")).bindingID
        )
    }

    func testRowIdentitySurvivesSourceReorderAndRebinding() {
        var parameter = MacIRFunctionParameter(
            id: .init(rawValue: "row:value"),
            bindingID: .gpr(0),
            sourcePosition: 0,
            abiLocation: .gpr(index: 0, carrierWidth: 64),
            type: "int64_t",
            name: "value",
            evidence: .authoritativeUser
        )!
        let originalID = parameter.id

        parameter.sourcePosition = 2
        XCTAssertTrue(parameter.rebind(
            bindingID: .simd(0),
            abiLocation: .simd(index: 0, scalarWidth: 64)
        ))

        XCTAssertEqual(parameter.id, originalID)
        XCTAssertEqual(parameter.bindingID, .simd(0))
        XCTAssertEqual(parameter.sourcePosition, 2)
    }

    func testBoundAndUnboundRowsRetainUniqueListIdentity() {
        let bound = MacIRFunctionParameter(
            id: .init(rawValue: "row:bound"),
            bindingID: .gpr(0),
            sourcePosition: 0,
            abiLocation: .gpr(index: 0, carrierWidth: 64),
            type: "int64_t",
            name: "value",
            evidence: .heuristicEntryRead
        )!
        let unbound = MacIRFunctionParameter(
            id: .init(rawValue: "row:unbound"),
            bindingID: nil,
            sourcePosition: 0,
            abiLocation: .unbound(reason: .unsupportedType("struct Big")),
            type: "struct Big",
            name: "value",
            evidence: .authoritativeUser
        )!

        XCTAssertNotEqual(bound.id, unbound.id)
    }

    func testDuplicateUnboundSourcePositionsStillHaveDistinctRowIdentity() {
        let location = MacIRABIParameterLocation.unbound(reason: .unresolvedLegacy)
        let first = MacIRFunctionParameter(
            id: .init(rawValue: "legacy:0"),
            bindingID: nil,
            sourcePosition: 0,
            abiLocation: location,
            type: "unknown_t",
            name: "value",
            evidence: .unresolvedLegacy
        )!
        let second = MacIRFunctionParameter(
            id: .init(rawValue: "legacy:1"),
            bindingID: nil,
            sourcePosition: 0,
            abiLocation: location,
            type: "unknown_t",
            name: "value",
            evidence: .unresolvedLegacy
        )!

        XCTAssertNotEqual(first.id, second.id)
    }

    func testCompatibilityInitializerDoesNotInventSourcePosition() {
        let parameter = MacIRFunctionParameter(index: 3, register: "x3", type: "int64_t")

        XCTAssertEqual(parameter.bindingID, .gpr(3))
        XCTAssertEqual(parameter.abiLocation, .gpr(index: 3, carrierWidth: 64))
        XCTAssertNil(parameter.sourcePosition)
    }

    func testABIOnlyDefaultNamePreservesExactRegisterView() {
        let cases: [(MacIRParameterBindingID, MacIRABIParameterLocation, String)] = [
            (.gpr(1), .gpr(index: 1, carrierWidth: 32), "in_w1"),
            (.gpr(1), .gpr(index: 1, carrierWidth: 64), "in_x1"),
            (.simd(0), .simd(index: 0, scalarWidth: 32), "in_s0"),
            (.simd(0), .simd(index: 0, scalarWidth: 64), "in_d0"),
        ]

        for (offset, testCase) in cases.enumerated() {
            let parameter = MacIRFunctionParameter(
                id: .init(rawValue: "row:view:\(offset)"),
                bindingID: testCase.0,
                sourcePosition: nil,
                abiLocation: testCase.1,
                type: "scalar",
                evidence: .heuristicEntryRead
            )
            XCTAssertEqual(parameter?.name, testCase.2)
        }
    }

    func testMismatchedBindingAndLocationFailsClosed() {
        XCTAssertNil(MacIRFunctionParameter(
            id: .init(rawValue: "row:mismatch"),
            bindingID: .gpr(0),
            sourcePosition: 0,
            abiLocation: .simd(index: 0, scalarWidth: 64),
            type: "double",
            name: "value",
            evidence: .authoritativeUser
        ))
    }

    func testRegisterLocationsRequireTheirProjectedBinding() {
        XCTAssertNil(MacIRFunctionParameter(
            id: .init(rawValue: "row:dangling-gpr"),
            bindingID: nil,
            sourcePosition: 0,
            abiLocation: .gpr(index: 0, carrierWidth: 64),
            type: "int64_t",
            evidence: .authoritativeUser
        ))
        XCTAssertNil(MacIRFunctionParameter(
            id: .init(rawValue: "row:dangling-simd"),
            bindingID: nil,
            sourcePosition: 0,
            abiLocation: .simd(index: 0, scalarWidth: 64),
            type: "double",
            evidence: .authoritativeDebug
        ))

        var parameter = MacIRFunctionParameter(
            id: .init(rawValue: "row:bound-gpr"),
            bindingID: .gpr(0),
            sourcePosition: 0,
            abiLocation: .gpr(index: 0, carrierWidth: 64),
            type: "int64_t",
            evidence: .authoritativeUser
        )!
        XCTAssertFalse(parameter.rebind(
            bindingID: nil,
            abiLocation: .gpr(index: 1, carrierWidth: 64)
        ))
        XCTAssertEqual(parameter.bindingID, .gpr(0))
        XCTAssertEqual(parameter.abiLocation, .gpr(index: 0, carrierWidth: 64))
    }

    func testQualifiedPointerNormalizationFeedsTypeInferenceWithoutBroadeningGrammar() {
        for type in [
            "const char * restrict",
            "volatile struct Payload * const",
            "struct Payload*__restrict__",
        ] {
            let fact = typeStringToLattice(type)
            XCTAssertEqual(fact.lattice, .pointer, "expected strict pointer spelling: \(type)")
            XCTAssertTrue(fact.confidence)
            XCTAssertEqual(fact.exactTypeString, type)
        }

        for malformed in ["int[4]", "int &", "void (*)(int)", "int * const nonsense"] {
            XCTAssertEqual(
                typeStringToLattice(malformed).lattice,
                .unknown,
                "malformed declarator must remain outside the shared pointer grammar: \(malformed)"
            )
        }
    }

    func testInvalidLocationDoesNotProjectToBinding() {
        XCTAssertNil(MacIRABIParameterLocation.gpr(index: 8, carrierWidth: 64).bindingID)
        XCTAssertNil(MacIRABIParameterLocation.gpr(index: 0, carrierWidth: 16).bindingID)
        XCTAssertNil(MacIRABIParameterLocation.simd(index: -1, scalarWidth: 64).bindingID)
        XCTAssertNil(MacIRABIParameterLocation.entryStack(byteOffset: -1, size: 1, alignment: 1).bindingID)
    }

    func testAuthoritativePlanRequiresContiguousPositionsAndUniqueBindings() {
        let first = MacIRFunctionParameter(
            id: .init(rawValue: "row:0"),
            bindingID: .gpr(0),
            sourcePosition: 0,
            abiLocation: .gpr(index: 0, carrierWidth: 64),
            type: "int64_t",
            evidence: .authoritativeUser
        )!
        let second = MacIRFunctionParameter(
            id: .init(rawValue: "row:1"),
            bindingID: .simd(0),
            sourcePosition: 1,
            abiLocation: .simd(index: 0, scalarWidth: 64),
            type: "double",
            evidence: .authoritativeUser
        )!

        XCTAssertNotNil(MacIRAuthoritativeParameterPlan(parameters: [], isVariadic: false))
        XCTAssertNotNil(MacIRAuthoritativeParameterPlan(parameters: [first, second], isVariadic: true))

        var gapped = second
        gapped.sourcePosition = 2
        XCTAssertNil(MacIRAuthoritativeParameterPlan(parameters: [first, gapped], isVariadic: false))

        var duplicate = second
        XCTAssertTrue(duplicate.rebind(
            bindingID: .gpr(0),
            abiLocation: .gpr(index: 0, carrierWidth: 64)
        ))
        XCTAssertNil(MacIRAuthoritativeParameterPlan(parameters: [first, duplicate], isVariadic: false))
    }
}

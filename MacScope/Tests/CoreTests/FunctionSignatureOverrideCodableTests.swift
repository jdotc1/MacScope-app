import Foundation
import XCTest
@testable import MacScope

final class FunctionSignatureOverrideCodableTests: XCTestCase {
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    // MARK: - Schema-v3 active-list presence

    func testDefaultInitializerLeavesParameterListUnspecified() throws {
        let signature = FunctionSignatureOverride()

        assertUnspecified(signature)
        XCTAssertTrue(signature.args.isEmpty)

        let object = try encodedObject(signature)
        XCTAssertEqual(object["schemaVersion"] as? Int, 3)
        XCTAssertNil(object["parameterList"], "an unspecified list must be omitted, not encoded as explicit void")
    }

    func testSchemaV2AbsentParameterListDecodesAsUnspecified() throws {
        let signature = try decode(
            """
            {"schemaVersion":2,"variadicState":"unspecified","isNoReturn":false}
            """
        )

        assertUnspecified(signature)
        XCTAssertTrue(signature.args.isEmpty)
    }

    func testExplicitEmptyInitializerRoundTripsAsAuthoritativeVoid() throws {
        let signature = FunctionSignatureOverride(args: [])

        assertAuthoritative(signature, expectedCount: 0)
        XCTAssertTrue(signature.args.isEmpty)

        let object = try encodedObject(signature)
        XCTAssertEqual(object["schemaVersion"] as? Int, 3)
        XCTAssertEqual((object["parameterList"] as? [Any])?.count, 0)

        let decoded = try roundTrip(signature)
        assertAuthoritative(decoded, expectedCount: 0)
    }

    func testAuthoritativeRowsEncodeInArrayOrderWithoutLegacyIndex() throws {
        let first = ArgOverride(rowToken: "row-z", name: "ratio", type: "double", provenance: .user)
        let second = ArgOverride(rowToken: "row-a", name: "context", type: "const int *", provenance: .script)
        let signature = FunctionSignatureOverride(args: [first, second])

        let object = try encodedObject(signature)
        let rows = try XCTUnwrap(object["parameterList"] as? [[String: Any]])
        XCTAssertEqual(rows.map { $0["rowToken"] as? String }, ["row-z", "row-a"])
        XCTAssertEqual(rows.map { $0["name"] as? String }, ["ratio", "context"])
        XCTAssertEqual(rows.map { $0["type"] as? String }, ["double", "const int *"])
        XCTAssertEqual(rows.map { $0["provenance"] as? String }, ["user", "script"])
        XCTAssertTrue(rows.allSatisfy { $0["index"] == nil }, "schema v2 array order is the sole source-order truth")
        XCTAssertNil(object["args"], "schema v2 must not emit the ambiguous legacy key")

        let decoded = try roundTrip(signature)
        assertAuthoritative(decoded, expectedCount: 2)
        XCTAssertEqual(decoded.args, [first, second])
    }

    func testSchemaV2DecodesAllDeclaratorVariadicStates() throws {
        for rawValue in ["unspecified", "fixed", "variadic"] {
            let signature = try decode(
                """
                {
                  "schemaVersion": 2,
                  "parameterList": [],
                  "variadicState": "\(rawValue)",
                  "isNoReturn": false
                }
                """
            )

            XCTAssertEqual(signature.variadicState.rawValue, rawValue)
            XCTAssertEqual(try encodedObject(signature)["variadicState"] as? String, rawValue)
        }
    }

    func testSchemaV2QuarantineRoundTripsSeparatelyFromActiveRows() throws {
        let signature = try decode(
            """
            {
              "schemaVersion": 2,
              "parameterList": [
                {"rowToken":"active-0","name":"value","type":"int","provenance":"user"}
              ],
              "variadicState": "fixed",
              "quarantinedLegacyArgs": [
                {"originalIndex":4,"originalOrder":0,"name":"mystery","type":"double"},
                {"originalIndex":0,"originalOrder":1,"name":"head","type":"int"}
              ],
              "isNoReturn": false
            }
            """
        )

        assertAuthoritative(signature, expectedCount: 1)
        XCTAssertEqual(signature.args.map(\.name), ["value"])
        XCTAssertEqual(signature.quarantinedLegacyArgs, [
            LegacyArgOverride(originalIndex: 4, originalOrder: 0, name: "mystery", type: "double"),
            LegacyArgOverride(originalIndex: 0, originalOrder: 1, name: "head", type: "int")
        ])
        XCTAssertTrue(signature.hasPersistedPayload)
        XCTAssertTrue(signature.hasAnalysisEffect, "the active list has effect even though quarantine itself does not")

        let decoded = try roundTrip(signature)
        XCTAssertEqual(decoded, signature)
    }

    // MARK: - Legacy migration

    func testDenseIntegerAndPointerLegacyRowsMigrateToAuthoritativeSourceOrder() throws {
        let signature = try decodeLegacy(rows: [
            legacyRow(index: 0, name: "count", type: "uint32_t"),
            legacyRow(index: 1, name: "buffer", type: "const char *"),
            legacyRow(index: 2, name: "cookie", type: "uint64_t")
        ])

        assertAuthoritative(signature, expectedCount: 3)
        XCTAssertEqual(signature.args.map(\.name), ["count", "buffer", "cookie"])
        XCTAssertEqual(signature.args.map(\.type), ["uint32_t", "const char *", "uint64_t"])
        XCTAssertEqual(signature.args.map(\.provenance), [.legacy, .legacy, .legacy])
        XCTAssertTrue(signature.args.allSatisfy { !$0.rowToken.isEmpty })
        XCTAssertEqual(Set(signature.args.map(\.rowToken)).count, 3)
        XCTAssertTrue(signature.quarantinedLegacyArgs.isEmpty)

        let object = try encodedObject(signature)
        XCTAssertEqual(object["schemaVersion"] as? Int, 3)
        XCTAssertNotNil(object["parameterList"])
        XCTAssertNil(object["args"])
    }

    func testSafeLegacyMigrationProducesDeterministicIdentityAndSchemaV3Bytes() throws {
        let legacyJSON = """
        {
          "returnType":"size_t",
          "args":[
            {"index":0,"name":"count","type":"uint32_t"},
            {"index":1,"name":"buffer","type":"const char *"}
          ],
          "isNoReturn":false
        }
        """

        let first = try decode(legacyJSON)
        let second = try decode(legacyJSON)

        XCTAssertEqual(first.args.map(\.rowToken), second.args.map(\.rowToken))
        XCTAssertEqual(first, second, "identical legacy evidence must reconstruct identical row identity")
        XCTAssertEqual(
            try sortedEncoding(first),
            try sortedEncoding(second),
            "identical legacy evidence must produce byte-identical canonical schema-v3 JSON"
        )
    }

    func testSparseLegacyRowsAreQuarantined() throws {
        try assertLegacyRowsQuarantined([
            legacyRow(index: 0, name: "first", type: "int"),
            legacyRow(index: 2, name: "third", type: "long")
        ])
    }

    func testNonzeroFirstLegacyRowIsQuarantined() throws {
        try assertLegacyRowsQuarantined([
            legacyRow(index: 1, name: "second", type: "int")
        ])
    }

    func testFloatingPointLegacyRowsAreQuarantined() throws {
        try assertLegacyRowsQuarantined([
            legacyRow(index: 0, name: "ratio", type: "double")
        ])
    }

    func testMixedBankLegacyRowsAreQuarantinedAsAWhole() throws {
        try assertLegacyRowsQuarantined([
            legacyRow(index: 0, name: "count", type: "int"),
            legacyRow(index: 1, name: "ratio", type: "float")
        ])
    }

    func testDuplicateLegacyIndicesAreQuarantined() throws {
        try assertLegacyRowsQuarantined([
            legacyRow(index: 0, name: "lhs", type: "int"),
            legacyRow(index: 0, name: "rhs", type: "int")
        ])
    }

    func testNegativeLegacyIndexIsQuarantined() throws {
        try assertLegacyRowsQuarantined([
            legacyRow(index: -1, name: "before", type: "int")
        ])
    }

    func testUnknownLegacyTypeIsQuarantined() throws {
        try assertLegacyRowsQuarantined([
            legacyRow(index: 0, name: "opaque", type: "MysteryHandle")
        ])
    }

    func testMalformedAndUnprovenLegacyPointerSpellingsAreQuarantined() throws {
        let unprovenPointerTypes = [
            "const *",
            "struct *",
            "if *",
            "Mystery Other *",
            "int; *",
        ]

        for type in unprovenPointerTypes {
            try assertLegacyRowsQuarantined([
                legacyRow(index: 0, name: "value", type: type)
            ])
        }
    }

    func testRestrictQualifiedAndContradictoryLegacyIntegerSpellingsAreQuarantined() throws {
        let unsupportedIntegerTypes = [
            "restrict int",
            "__restrict int",
            "__restrict__ int",
            "int int",
            "signed unsigned int",
            "long long long",
            "short long",
        ]

        for type in unsupportedIntegerTypes {
            try assertLegacyRowsQuarantined([
                legacyRow(index: 0, name: "value", type: type)
            ])
        }
    }

    func testCVQualifiedSupportedLegacyIntegersMigrateWithoutOverQuarantine() throws {
        let signature = try decodeLegacy(rows: [
            legacyRow(index: 0, name: "plain", type: "const int"),
            legacyRow(index: 1, name: "reordered", type: "unsigned long volatile"),
            legacyRow(index: 2, name: "combined", type: "const volatile uint32_t"),
        ])

        assertAuthoritative(signature, expectedCount: 3)
        XCTAssertEqual(
            signature.args.map(\.type),
            ["const int", "unsigned long volatile", "const volatile uint32_t"]
        )
        XCTAssertTrue(signature.quarantinedLegacyArgs.isEmpty)
    }

    func testProvableLegacyDataPointerSpellingsMigrateWithoutOverQuarantine() throws {
        let signature = try decodeLegacy(rows: [
            legacyRow(index: 0, name: "plain", type: "int*"),
            legacyRow(index: 1, name: "qualified", type: "const int *"),
            legacyRow(index: 2, name: "opaque", type: "OpaqueHandle *"),
            legacyRow(index: 3, name: "tagged", type: "struct Payload *"),
            legacyRow(index: 4, name: "indirect", type: "void **"),
            legacyRow(index: 5, name: "pointerQualified", type: "int * restrict"),
        ])

        assertAuthoritative(signature, expectedCount: 6)
        XCTAssertEqual(
            signature.args.map(\.type),
            [
                "int*", "const int *", "OpaqueHandle *", "struct Payload *", "void **",
                "int * restrict",
            ]
        )
        XCTAssertTrue(signature.quarantinedLegacyArgs.isEmpty)
    }

    func testQuarantinePreservesOriginalIndexArrayOrderNameAndType() throws {
        let rows = [
            legacyRow(index: 3, name: "late", type: "double"),
            legacyRow(index: 0, name: "early", type: "int")
        ]
        let signature = try decodeLegacy(rows: rows)

        XCTAssertEqual(signature.quarantinedLegacyArgs, [
            LegacyArgOverride(originalIndex: 3, originalOrder: 0, name: "late", type: "double"),
            LegacyArgOverride(originalIndex: 0, originalOrder: 1, name: "early", type: "int")
        ])

        let roundTripped = try roundTrip(signature)
        XCTAssertEqual(roundTripped.quarantinedLegacyArgs, signature.quarantinedLegacyArgs)
    }

    func testProgrammaticDuplicateAndEmptyRowTokensNormalizeDeterministicallyAndRoundTrip() throws {
        func makeSignature() -> FunctionSignatureOverride {
            FunctionSignatureOverride(parameterList: .authoritative([
                ArgOverride(rowToken: "", name: "first", type: "int", provenance: .user),
                ArgOverride(rowToken: "duplicate", name: "second", type: "long", provenance: .user),
                ArgOverride(rowToken: "duplicate", name: "third", type: "char *", provenance: .script)
            ]))
        }

        let first = makeSignature()
        let second = makeSignature()
        let tokens = first.args.map(\.rowToken)

        XCTAssertTrue(tokens.allSatisfy { !$0.isEmpty })
        XCTAssertEqual(Set(tokens).count, tokens.count)
        XCTAssertEqual(first, second, "normalizing identical invalid tokens must not inject random identity")
        XCTAssertEqual(try sortedEncoding(first), try sortedEncoding(second))
        XCTAssertEqual(try roundTrip(first), first)
    }

    func testProgrammaticNoncanonicalQuarantineNormalizesToArrayOrderAndRoundTrips() throws {
        let signature = FunctionSignatureOverride(quarantinedLegacyArgs: [
            LegacyArgOverride(originalIndex: 7, originalOrder: 91, name: "late", type: "double"),
            LegacyArgOverride(originalIndex: -1, originalOrder: 91, name: "early", type: "Mystery")
        ])

        XCTAssertEqual(signature.quarantinedLegacyArgs.map(\.originalOrder), [0, 1])
        XCTAssertEqual(signature.quarantinedLegacyArgs.map(\.originalIndex), [7, -1])
        XCTAssertEqual(try roundTrip(signature), signature)
    }

    func testEncodingFailsClosedWhenCanonicalQuarantineOrderIsLaterCorrupted() throws {
        var signature = FunctionSignatureOverride(quarantinedLegacyArgs: [
            LegacyArgOverride(originalIndex: 4, originalOrder: 0, name: "value", type: "double")
        ])
        signature.quarantinedLegacyArgs[0].originalOrder = 3

        XCTAssertThrowsError(try encoder.encode(signature))
    }

    func testLegacyEmptyArgsWithReturnOnlyChangeBecomesUnspecified() throws {
        let signature = try decode(
            """
            {"returnType":"size_t","args":[],"isNoReturn":false}
            """
        )

        assertUnspecified(signature)
        XCTAssertEqual(signature.returnType, "size_t")
        XCTAssertTrue(signature.hasPersistedPayload)
        XCTAssertTrue(signature.hasAnalysisEffect)
    }

    func testLegacyEmptyArgsWithNoReturnOnlyChangeBecomesUnspecified() throws {
        let signature = try decode(
            """
            {"returnType":null,"args":[],"isNoReturn":true}
            """
        )

        assertUnspecified(signature)
        XCTAssertEqual(signature.noReturnState, .noReturn)
        XCTAssertTrue(signature.hasPersistedPayload)
        XCTAssertTrue(signature.hasAnalysisEffect)
    }

    // MARK: - Fail-closed decoding

    func testUnknownSchemaVersionFailsClosed() {
        XCTAssertThrowsError(
            try decode(
                """
                {"schemaVersion":4,"parameterList":[],"variadicState":"fixed","noReturnState":"unspecified"}
                """
            )
        )
    }

    func testMalformedSchemaV2RowFailsClosed() {
        XCTAssertThrowsError(
            try decode(
                """
                {
                  "schemaVersion":2,
                  "parameterList":[{"rowToken":"r0","name":"value","type":17,"provenance":"user"}],
                  "variadicState":"fixed",
                  "isNoReturn":false
                }
                """
            )
        )
    }

    // MARK: - Persistence versus analysis effect

    func testEmptyUnspecifiedOverrideHasNeitherPersistedPayloadNorAnalysisEffect() {
        let signature = FunctionSignatureOverride()

        XCTAssertFalse(signature.hasPersistedPayload)
        XCTAssertFalse(signature.hasAnalysisEffect)
    }

    func testExplicitVoidHasPersistedPayloadAndAnalysisEffect() {
        let signature = FunctionSignatureOverride(args: [])

        XCTAssertTrue(signature.hasPersistedPayload)
        XCTAssertTrue(signature.hasAnalysisEffect)
    }

    func testAuthoritativeNonemptyListHasPersistedPayloadAndAnalysisEffect() {
        let signature = FunctionSignatureOverride(args: [
            ArgOverride(rowToken: "r0", name: "value", type: "int", provenance: .user)
        ])

        XCTAssertTrue(signature.hasPersistedPayload)
        XCTAssertTrue(signature.hasAnalysisEffect)
    }

    func testQuarantineAlonePersistsWithoutAnalysisEffect() throws {
        let signature = try decodeLegacy(rows: [
            legacyRow(index: 2, name: "ambiguous", type: "int")
        ])

        assertUnspecified(signature)
        XCTAssertEqual(signature.quarantinedLegacyArgs.count, 1)
        XCTAssertTrue(signature.hasPersistedPayload)
        XCTAssertFalse(signature.hasAnalysisEffect)
    }

    func testReturnTypeOnlyHasPersistedPayloadAndAnalysisEffectWithoutActivatingList() {
        let signature = FunctionSignatureOverride(returnType: "Result")

        assertUnspecified(signature)
        XCTAssertTrue(signature.hasPersistedPayload)
        XCTAssertTrue(signature.hasAnalysisEffect)
    }

    func testNoReturnOnlyHasPersistedPayloadAndAnalysisEffectWithoutActivatingList() {
        let signature = FunctionSignatureOverride(noReturnState: .noReturn)

        assertUnspecified(signature)
        XCTAssertTrue(signature.hasPersistedPayload)
        XCTAssertTrue(signature.hasAnalysisEffect)
    }

    func testSchemaV3RoundTripsEveryNoReturnState() throws {
        for state in FunctionSignatureOverride.NoReturnState.allCases {
            let value = FunctionSignatureOverride(noReturnState: state)
            let object = try encodedObject(value)
            XCTAssertEqual(object["schemaVersion"] as? Int, 3)
            XCTAssertEqual(object["noReturnState"] as? String, state.rawValue)
            XCTAssertNil(object["isNoReturn"])
            XCTAssertEqual(try roundTrip(value).noReturnState, state)
        }
    }

    func testLegacyNoReturnBooleanMapsToTriStateWithoutInventingClear() throws {
        XCTAssertEqual(try decode("{\"isNoReturn\":true}").noReturnState, .noReturn)
        XCTAssertEqual(try decode("{\"isNoReturn\":false}").noReturnState, .unspecified)
        XCTAssertEqual(try decode("{}").noReturnState, .unspecified)
        XCTAssertEqual(
            try decode("{\"schemaVersion\":2,\"isNoReturn\":true}").noReturnState,
            .noReturn
        )
        XCTAssertEqual(
            try decode("{\"schemaVersion\":2,\"isNoReturn\":false}").noReturnState,
            .unspecified
        )
    }

    func testNoReturnOnlySetAndClearHaveAnalysisEffect() {
        XCTAssertFalse(FunctionSignatureOverride(noReturnState: .unspecified).hasAnalysisEffect)
        XCTAssertTrue(FunctionSignatureOverride(noReturnState: .returns).hasAnalysisEffect)
        XCTAssertTrue(FunctionSignatureOverride(noReturnState: .noReturn).hasAnalysisEffect)
    }

    func testLegacyBooleanSourceCompatibilityOverloadsMapWithoutInventingClear() {
        let row = ArgOverride(rowToken: "legacy-row", name: "value", type: "int", provenance: .user)
        let quarantine = [
            LegacyArgOverride(originalIndex: 3, originalOrder: 0, name: "ambiguous", type: "Mystery")
        ]

        let fullFalse = FunctionSignatureOverride(
            returnType: "int",
            parameterList: .unspecified,
            variadicState: .variadic,
            quarantinedLegacyArgs: quarantine,
            isNoReturn: false
        )
        let fullTrue = FunctionSignatureOverride(
            returnType: "Never",
            parameterList: .unspecified,
            variadicState: .fixed,
            quarantinedLegacyArgs: quarantine,
            isNoReturn: true
        )
        XCTAssertEqual(fullFalse.noReturnState, .unspecified)
        XCTAssertEqual(fullTrue.noReturnState, .noReturn)
        XCTAssertEqual(fullFalse.variadicState, .variadic)
        XCTAssertEqual(fullFalse.quarantinedLegacyArgs, quarantine)

        let shorthandFalse = FunctionSignatureOverride(isNoReturn: false)
        let shorthandTrue = FunctionSignatureOverride(isNoReturn: true)
        XCTAssertEqual(shorthandFalse.noReturnState, .unspecified)
        XCTAssertEqual(shorthandTrue.noReturnState, .noReturn)

        let argsFalse = FunctionSignatureOverride(returnType: "int", args: [row], isNoReturn: false)
        let argsTrue = FunctionSignatureOverride(returnType: "Never", args: [row], isNoReturn: true)
        XCTAssertEqual(argsFalse.noReturnState, .unspecified)
        XCTAssertEqual(argsTrue.noReturnState, .noReturn)
        XCTAssertEqual(argsFalse.args, [row])
        XCTAssertEqual(argsFalse.variadicState, .fixed)

        let authoritativeFalse = FunctionSignatureOverride.authoritative(
            returnType: "int",
            args: [row],
            variadicState: .variadic,
            isNoReturn: false
        )
        let authoritativeTrue = FunctionSignatureOverride.authoritative(
            returnType: "Never",
            args: [row],
            variadicState: .fixed,
            isNoReturn: true
        )
        XCTAssertEqual(authoritativeFalse.noReturnState, .unspecified)
        XCTAssertEqual(authoritativeTrue.noReturnState, .noReturn)
        XCTAssertEqual(authoritativeFalse.args, [row])
        XCTAssertEqual(authoritativeFalse.variadicState, .variadic)
    }

    // MARK: - Helpers

    private func decode(_ json: String) throws -> FunctionSignatureOverride {
        try decoder.decode(FunctionSignatureOverride.self, from: Data(json.utf8))
    }

    private func decodeLegacy(rows: [[String: Any]]) throws -> FunctionSignatureOverride {
        let data = try JSONSerialization.data(withJSONObject: [
            "returnType": NSNull(),
            "args": rows,
            "isNoReturn": false
        ], options: [.sortedKeys])
        return try decoder.decode(FunctionSignatureOverride.self, from: data)
    }

    private func legacyRow(index: Int, name: String, type: String) -> [String: Any] {
        ["index": index, "name": name, "type": type]
    }

    private func roundTrip(_ signature: FunctionSignatureOverride) throws -> FunctionSignatureOverride {
        try decoder.decode(FunctionSignatureOverride.self, from: encoder.encode(signature))
    }

    private func encodedObject(_ signature: FunctionSignatureOverride) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: encoder.encode(signature))
        return try XCTUnwrap(object as? [String: Any])
    }

    private func sortedEncoding(_ signature: FunctionSignatureOverride) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(signature)
    }

    private func assertUnspecified(
        _ signature: FunctionSignatureOverride,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .unspecified = signature.parameterList else {
            return XCTFail("expected an unspecified parameter list", file: file, line: line)
        }
    }

    private func assertAuthoritative(
        _ signature: FunctionSignatureOverride,
        expectedCount: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case let .authoritative(rows) = signature.parameterList else {
            return XCTFail("expected an authoritative parameter list", file: file, line: line)
        }
        XCTAssertEqual(rows.count, expectedCount, file: file, line: line)
    }

    private func assertLegacyRowsQuarantined(
        _ rows: [[String: Any]],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let signature = try decodeLegacy(rows: rows)
        assertUnspecified(signature, file: file, line: line)
        XCTAssertTrue(signature.args.isEmpty, file: file, line: line)
        XCTAssertEqual(signature.quarantinedLegacyArgs.count, rows.count, file: file, line: line)
        XCTAssertTrue(signature.hasPersistedPayload, file: file, line: line)
        XCTAssertFalse(signature.hasAnalysisEffect, file: file, line: line)
    }
}

import XCTest
@testable import MacScope

/// WS-14: authoritative source rows are bound through the strict Darwin arm64
/// scalar ABI. The binder must abstain when a type could change later cursor
/// state; it must never fall back to the permissive call-signature allocator.
final class DarwinARM64ParameterBinderTests: XCTestCase {
    func testMixedScalarSourceOrderUsesIndependentRegisterBanks() {
        XCTAssertEqual(
            bind(["int", "double", "float", "void *"]),
            [
                .gpr(index: 0, carrierWidth: 32),
                .simd(index: 0, scalarWidth: 64),
                .simd(index: 1, scalarWidth: 32),
                .gpr(index: 1, carrierWidth: 64),
            ]
        )
    }

    func testSIMDZeroAndGPRZeroDoNotCollide() {
        XCTAssertEqual(
            bind(["double", "char *"]),
            [
                .simd(index: 0, scalarWidth: 64),
                .gpr(index: 0, carrierWidth: 64),
            ]
        )
    }

    func testNarrowIntegersUseThirtyTwoBitRegisterCarriers() {
        XCTAssertEqual(
            bind(["char", "signed char", "unsigned char", "short", "unsigned short"]),
            (0..<5).map { .gpr(index: $0, carrierWidth: 32) }
        )
    }

    func testLegacyMigrationIntegerTypedefsUseOracleBackedDarwinWidths() throws {
        let expectedSizes: [(type: String, size: Int)] = [
            ("time_t", 8),
            ("clock_t", 8),
            ("pid_t", 4),
            ("uid_t", 4),
            ("gid_t", 4),
            ("mode_t", 2),
            ("socklen_t", 4),
        ]

        for (type, size) in expectedSizes {
            let carrierWidth = size <= 4 ? 32 : 64
            XCTAssertEqual(
                bind([type]),
                [.gpr(index: 0, carrierWidth: carrierWidth)],
                "\(type) must remain bindable after safe legacy migration"
            )

            let spilled = bind(Array(repeating: type, count: 9))
            XCTAssertEqual(
                try XCTUnwrap(spilled.last),
                .entryStack(byteOffset: 0, size: size, alignment: size),
                "\(type) must keep its natural Darwin stack size and alignment"
            )
        }
    }

    func testPointerWhitespaceAndQualifiersHaveEquivalentPlacement() {
        XCTAssertEqual(
            bind([
                "int*",
                "int *",
                "const int *",
                "volatile unsigned char * restrict",
                "struct Opaque * const",
            ]),
            (0..<5).map { .gpr(index: $0, carrierWidth: 64) }
        )
    }

    func testArraysReferencesFunctionDeclaratorsAndMalformedPointersAreUnsupported() {
        let unsupportedTypes = [
            "int[4]",
            "int &",
            "void (*)(int)",
            "int * const nonsense",
        ]

        for type in unsupportedTypes {
            XCTAssertEqual(
                bind([type]),
                [.unbound(reason: .unsupportedType(type))],
                "unexpected classification for \(type)"
            )
        }
    }

    func testReservedWordsAndMalformedAggregateTagsPoisonLaterRows() {
        let unsupportedTypes = [
            "struct int *",
            "union while *",
            "enum return *",
            "struct const Opaque *",
            "union volatile Payload *",
            "restrict *",
            "static *",
            "return *",
        ]

        for type in unsupportedTypes {
            XCTAssertEqual(
                bind([type, "int"]),
                [
                    .unbound(reason: .unsupportedType(type)),
                    .unbound(reason: .dependentOnUnsupportedEarlierParameter),
                ],
                "invalid pointer grammar must fail closed for \(type)"
            )
        }
    }

    func testNinthIntegerUsesEntryStackAndNeverX8() {
        let locations = bind(Array(repeating: "int64_t", count: 9))

        XCTAssertEqual(
            locations,
            (0..<8).map { .gpr(index: $0, carrierWidth: 64) }
                + [.entryStack(byteOffset: 0, size: 8, alignment: 8)]
        )
        XCTAssertFalse(locations.contains(.gpr(index: 8, carrierWidth: 64)))
    }

    func testNinthFloatingScalarUsesEntryStackAndNeverD8() {
        let locations = bind(Array(repeating: "double", count: 9))

        XCTAssertEqual(
            locations,
            (0..<8).map { .simd(index: $0, scalarWidth: 64) }
                + [.entryStack(byteOffset: 0, size: 8, alignment: 8)]
        )
        XCTAssertFalse(locations.contains(.simd(index: 8, scalarWidth: 64)))
    }

    func testSpilledSIMDBankDoesNotPreventGPRBankFromContinuing() {
        let locations = bind(
            Array(repeating: "double", count: 9)
                + ["int", "double", "void *"]
        )

        XCTAssertEqual(locations[8], .entryStack(byteOffset: 0, size: 8, alignment: 8))
        XCTAssertEqual(locations[9], .gpr(index: 0, carrierWidth: 32))
        XCTAssertEqual(locations[10], .entryStack(byteOffset: 8, size: 8, alignment: 8))
        XCTAssertEqual(locations[11], .gpr(index: 1, carrierWidth: 64))
    }

    func testSpilledGPRBankDoesNotPreventSIMDBankFromContinuing() {
        let locations = bind(
            Array(repeating: "int64_t", count: 9)
                + ["float", "int64_t", "double"]
        )

        XCTAssertEqual(locations[8], .entryStack(byteOffset: 0, size: 8, alignment: 8))
        XCTAssertEqual(locations[9], .simd(index: 0, scalarWidth: 32))
        XCTAssertEqual(locations[10], .entryStack(byteOffset: 8, size: 8, alignment: 8))
        XCTAssertEqual(locations[11], .simd(index: 1, scalarWidth: 64))
    }

    func testBothBanksShareOneAlignedNSAA() {
        let locations = bind(
            Array(repeating: "int64_t", count: 8)
                + Array(repeating: "double", count: 8)
                + ["char", "double", "short"]
        )

        XCTAssertEqual(locations[16], .entryStack(byteOffset: 0, size: 1, alignment: 1))
        XCTAssertEqual(locations[17], .entryStack(byteOffset: 8, size: 8, alignment: 8))
        XCTAssertEqual(locations[18], .entryStack(byteOffset: 16, size: 2, alignment: 2))
    }

    func testDarwinStackPackingKeepsAdjacentCharsBytePacked() {
        let locations = bind(Array(repeating: "char", count: 10))

        XCTAssertEqual(locations[8], .entryStack(byteOffset: 0, size: 1, alignment: 1))
        XCTAssertEqual(locations[9], .entryStack(byteOffset: 1, size: 1, alignment: 1))
    }

    func testUnsupportedRowPoisonsEveryDependentLaterLocation() {
        XCTAssertEqual(
            bind(["int", "struct Big", "double", "void *"]),
            [
                .gpr(index: 0, carrierWidth: 32),
                .unbound(reason: .unsupportedType("struct Big")),
                .unbound(reason: .dependentOnUnsupportedEarlierParameter),
                .unbound(reason: .dependentOnUnsupportedEarlierParameter),
            ]
        )
    }

    func testVariadicDeclarationBindsOnlyNamedFixedRows() {
        let locations = DarwinARM64ParameterBinder.bind(
            parameterTypes: ["const char *", "int", "double"],
            isVariadic: true
        )

        XCTAssertEqual(
            locations,
            [
                .gpr(index: 0, carrierWidth: 64),
                .gpr(index: 1, carrierWidth: 32),
                .simd(index: 0, scalarWidth: 64),
            ]
        )
        XCTAssertEqual(locations.count, 3, "variadic tail must not fabricate an ABI row")
    }

    private func bind(_ parameterTypes: [String]) -> [MacIRABIParameterLocation] {
        DarwinARM64ParameterBinder.bind(parameterTypes: parameterTypes)
    }
}

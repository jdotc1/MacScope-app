import Foundation
import XCTest
@testable import MacScope

final class DebuggerLogicalBreakpointModelTests: XCTestCase {
    func testAuthoredIdentityUsesExactUTF8BytesInsteadOfCanonicalUnicodeEquivalence() throws {
        let composed = "\u{00E9}"
        let decomposed = "e\u{0301}"
        XCTAssertEqual(composed, decomposed, "The standard String comparison demonstrates the hazard.")

        XCTAssertNotEqual(
            DebuggerCanonicalSourceTablePath.compilationDirectoryRelativeUTF8(composed),
            DebuggerCanonicalSourceTablePath.compilationDirectoryRelativeUTF8(decomposed)
        )

        let composedSpec = try specification(condition: composed)
        let decomposedSpec = try specification(condition: decomposed)
        XCTAssertNotEqual(composedSpec, decomposedSpec)
        XCTAssertEqual(Set([composedSpec, decomposedSpec]).count, 2)
        XCTAssertNotEqual(
            try DebuggerLogicalBreakpointCanonicalCodec.encodeSpecification(composedSpec),
            try DebuggerLogicalBreakpointCanonicalCodec.encodeSpecification(decomposedSpec)
        )

        let composedSymbol = try specification(
            target: .symbol(
                owner: owner(),
                exactRawLinkageName: composed,
                kind: nil,
                libraryName: nil,
                cardinality: .exactlyOne
            )
        )
        let decomposedSymbol = try specification(
            target: .symbol(
                owner: owner(),
                exactRawLinkageName: decomposed,
                kind: nil,
                libraryName: nil,
                cardinality: .exactlyOne
            )
        )
        XCTAssertNotEqual(composedSymbol, decomposedSymbol)

        let composedAction = try specification(
            actions: [.evaluateTargetExpression(try .init(label: "value", expression: composed))]
        )
        let decomposedAction = try specification(
            actions: [.evaluateTargetExpression(try .init(label: "value", expression: decomposed))]
        )
        XCTAssertNotEqual(composedAction, decomposedAction)
    }

    func testWorkspaceSnapshotInitializersPreserveInjectedCatalog() throws {
        let catalog = try DebuggerLogicalBreakpointCatalog(
            catalogID: UUID(uuidString: "ABABABAB-ABAB-ABAB-ABAB-ABABABABABAB")!,
            revision: 2,
            specifications: []
        )

        let imageAware = WorkspaceSnapshot(
            binaries: [],
            analysisBySlot: [:],
            logicalBreakpointCatalog: catalog
        )
        XCTAssertEqual(imageAware.logicalBreakpointCatalog, catalog)

        let compatibility = WorkspaceSnapshot(
            binaries: [],
            functions: [],
            instructions: [],
            xrefs: [],
            hexBytes: Data(),
            logicalBreakpointCatalog: catalog
        )
        XCTAssertEqual(compatibility.logicalBreakpointCatalog, catalog)
    }

    func testLogicalIdentityAndCatalogCoordinateRoundTripWithoutRewritingUUIDs() throws {
        let logicalID = DebuggerLogicalBreakpointID(
            rawValue: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        )
        let coordinate = try DebuggerLogicalBreakpointCatalogCoordinate(
            workspaceID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            catalogID: UUID(uuidString: "01234567-89AB-CDEF-0123-456789ABCDEF")!,
            revision: 41
        )

        XCTAssertEqual(
            try roundTrip(logicalID, as: DebuggerLogicalBreakpointID.self),
            logicalID
        )
        XCTAssertEqual(
            try roundTrip(coordinate, as: DebuggerLogicalBreakpointCatalogCoordinate.self),
            coordinate
        )
    }

    func testRevisionDomainMatchesSQLiteAndRefusesExhaustionWithoutWrapping() throws {
        XCTAssertThrowsError(try DebuggerLogicalBreakpointRevision(validating: 0))

        let maximum = try DebuggerLogicalBreakpointRevision(
            validating: UInt64(Int64.max)
        )
        XCTAssertEqual(maximum.rawValue, UInt64(Int64.max))
        XCTAssertThrowsError(try maximum.incremented())

        XCTAssertThrowsError(
            try DebuggerLogicalBreakpointRevision(
                validating: UInt64(Int64.max) + 1
            )
        )
        XCTAssertThrowsError(
            try DebuggerLogicalBreakpointCatalogCoordinate(
                workspaceID: UUID(),
                catalogID: UUID(),
                revision: 0
            )
        )
        XCTAssertThrowsError(
            try DebuggerLogicalBreakpointCatalogCoordinate(
                workspaceID: UUID(),
                catalogID: UUID(),
                revision: UInt64(Int64.max) + 1
            )
        )
    }

    func testCatalogCanonicalizesLogicalUUIDOrderAndRejectsDuplicateIDs() throws {
        let higher = try specification(
            id: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF",
            target: .preferredAddress(owner: owner(), preferredVA: 0x1_0000_1000)
        )
        let lower = try specification(
            id: "00000000-0000-0000-0000-000000000001",
            target: .preferredAddress(owner: owner(), preferredVA: 0x1_0000_1000)
        )
        let catalogID = UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!
        let reversed = try DebuggerLogicalBreakpointCatalog(
            catalogID: catalogID,
            revision: 2,
            specifications: [higher, lower]
        )
        let ordered = try DebuggerLogicalBreakpointCatalog(
            catalogID: catalogID,
            revision: 2,
            specifications: [lower, higher]
        )

        XCTAssertEqual(reversed.specifications.map(\.id), [lower.id, higher.id])
        XCTAssertEqual(
            try DebuggerLogicalBreakpointCanonicalCodec.encodeCatalog(reversed),
            try DebuggerLogicalBreakpointCanonicalCodec.encodeCatalog(ordered)
        )
        XCTAssertThrowsError(
            try DebuggerLogicalBreakpointCatalog(
                catalogID: catalogID,
                revision: 3,
                specifications: [lower, lower]
            )
        )
    }

    func testSameAddressSpecificationsRemainDistinctByLogicalIdentity() throws {
        let target = DebuggerLogicalBreakpointTarget.preferredAddress(
            owner: owner(),
            preferredVA: 0x1_0000_1000
        )
        let first = try specification(
            id: "11111111-1111-1111-1111-111111111111",
            target: target
        )
        let second = try specification(
            id: "22222222-2222-2222-2222-222222222222",
            target: target
        )
        let catalog = try DebuggerLogicalBreakpointCatalog(
            catalogID: UUID(),
            revision: 2,
            specifications: [second, first]
        )

        XCTAssertEqual(catalog.specifications.count, 2)
        XCTAssertNotEqual(catalog.specifications[0].id, catalog.specifications[1].id)
        XCTAssertEqual(catalog.specifications[0].target, catalog.specifications[1].target)
    }

    func testEveryFrozenLocatorRoundTripsCanonically() throws {
        let owner = owner()
        let sourceFile = try sourceFile(
            tablePath: .absoluteUTF8("/Volumes/Source Root/App/Sources/main.swift")
        )
        let targets: [DebuggerLogicalBreakpointTarget] = [
            .preferredAddress(owner: owner, preferredVA: 0x1_0000_1000),
            .imageOffset(
                owner: owner,
                segmentName: "__TEXT",
                expectedSegmentPreferredStart: 0x1_0000_0000,
                offset: 0x1000
            ),
            .function(
                owner: owner,
                entryPreferredVA: 0x1_0000_2000,
                rawLinkageNameHint: "_$s4Demo4mainyyF"
            ),
            .symbol(
                owner: owner,
                exactRawLinkageName: "_$s4Demo6workeryyF",
                kind: "T",
                libraryName: "DemoCore",
                cardinality: .allExactMatches
            ),
            .source(
                owner: owner,
                file: sourceFile,
                line: 27,
                columnPolicy: .exact(9),
                cardinality: .exactlyOne
            ),
        ]

        for (index, target) in targets.enumerated() {
            let value = try specification(
                id: String(format: "00000000-0000-0000-0000-%012d", index + 1),
                target: target
            )
            let encoded = try DebuggerLogicalBreakpointCanonicalCodec.encodeSpecification(value)
            XCTAssertEqual(
                try DebuggerLogicalBreakpointCanonicalCodec.decodeSpecification(encoded),
                value,
                "Locator at index \(index) did not preserve exact durable identity."
            )
            XCTAssertEqual(
                encoded,
                try DebuggerLogicalBreakpointCanonicalCodec.encodeSpecification(value),
                "Locator at index \(index) did not encode deterministically."
            )
        }
    }

    func testSourceIdentityPreservesExactTaggedPathAndArtifactEvidence() throws {
        let absolute = try sourceFile(tablePath: .absoluteUTF8("/tmp/A/../B/main.c"))
        let relative = try sourceFile(
            tablePath: .compilationDirectoryRelativeUTF8("Sources/./main.c")
        )

        XCTAssertEqual(
            try roundTrip(absolute, as: DebuggerCanonicalSourceFileIdentity.self),
            absolute
        )
        XCTAssertEqual(
            try roundTrip(relative, as: DebuggerCanonicalSourceFileIdentity.self),
            relative
        )
        XCTAssertNotEqual(absolute.tablePath, relative.tablePath)
        XCTAssertThrowsError(
            try sourceFile(tablePath: .absoluteUTF8("Sources/main.c"))
        )
        XCTAssertThrowsError(
            try sourceFile(
                tablePath: .compilationDirectoryRelativeUTF8("/Sources/main.c")
            )
        )
        XCTAssertThrowsError(try sourceFile(tablePath: .absoluteUTF8("")))
        XCTAssertThrowsError(
            try sourceFile(tablePath: .absoluteUTF8("/Sources/main\n.c"))
        )
        XCTAssertThrowsError(
            try DebuggerCanonicalSourceFileIdentity(
                debugArtifactUUID: UUID(),
                debugArtifactMachOSHA256: String(repeating: "A", count: 64),
                debugArtifactMachOByteCount: 1,
                lineProgramUnitOffset: 0,
                fileTableIndex: 0,
                tablePath: .absoluteUTF8("/Sources/main.c")
            )
        )
        XCTAssertThrowsError(
            try DebuggerCanonicalSourceFileIdentity(
                debugArtifactUUID: UUID(),
                debugArtifactMachOSHA256: String(repeating: "a", count: 64),
                debugArtifactMachOByteCount: 0,
                lineProgramUnitOffset: 0,
                fileTableIndex: 0,
                tablePath: .absoluteUTF8("/Sources/main.c")
            )
        )
    }

    func testSourceLineAndExactColumnMustBePositive() throws {
        let file = try sourceFile(tablePath: .absoluteUTF8("/Sources/main.c"))
        XCTAssertThrowsError(
            try specification(
                target: .source(
                    owner: owner(),
                    file: file,
                    line: 0,
                    columnPolicy: .any,
                    cardinality: .exactlyOne
                )
            )
        )
        XCTAssertThrowsError(
            try specification(
                target: .source(
                    owner: owner(),
                    file: file,
                    line: 1,
                    columnPolicy: .exact(0),
                    cardinality: .exactlyOne
                )
            )
        )
    }

    func testLocatorTextRejectsControlsAndOversizeCanonicalPayloads() throws {
        let owner = owner()
        let invalidTargets: [DebuggerLogicalBreakpointTarget] = [
            .imageOffset(
                owner: owner,
                segmentName: "__TE\nXT",
                expectedSegmentPreferredStart: 0x1_0000_0000,
                offset: 0
            ),
            .function(
                owner: owner,
                entryPreferredVA: 0x1_0000_1000,
                rawLinkageNameHint: "_main\u{202E}"
            ),
            .symbol(
                owner: owner,
                exactRawLinkageName: "_worker\t",
                kind: "T",
                libraryName: nil,
                cardinality: .exactlyOne
            ),
            .symbol(
                owner: owner,
                exactRawLinkageName: "_worker",
                kind: "T",
                libraryName: "Demo\u{2066}",
                cardinality: .exactlyOne
            ),
        ]

        for target in invalidTargets {
            XCTAssertThrowsError(try specification(target: target))
        }

        XCTAssertThrowsError(
            try specification(
                target: .symbol(
                    owner: owner,
                    exactRawLinkageName: String(repeating: "s", count: 17_000),
                    kind: nil,
                    libraryName: nil,
                    cardinality: .exactlyOne
                )
            )
        )
    }

    func testIgnoreFirstRejectsZeroAndAcceptsUInt32Maximum() throws {
        XCTAssertThrowsError(
            try specification(hitPolicy: .ignoreFirst(0))
        )

        let maximum = try specification(hitPolicy: .ignoreFirst(.max))
        XCTAssertEqual(maximum.hitPolicy, .ignoreFirst(.max))
        XCTAssertEqual(
            try DebuggerLogicalBreakpointCanonicalCodec.decodeSpecification(
                DebuggerLogicalBreakpointCanonicalCodec.encodeSpecification(maximum)
            ),
            maximum
        )
    }

    func testConditionUsesUTF8ByteLimitAndRejectsSpoofingControls() throws {
        let exactlyOneKiB = String(repeating: "é", count: 512)
        XCTAssertEqual(exactlyOneKiB.utf8.count, 1_024)
        XCTAssertNoThrow(try specification(condition: exactlyOneKiB))
        XCTAssertThrowsError(try specification(condition: exactlyOneKiB + "a"))

        for control in ["\0", "\n", "\r", "\t", "\u{007F}", "\u{2028}", "\u{2029}", "\u{202E}"] {
            XCTAssertThrowsError(
                try specification(condition: "lhs\(control)rhs"),
                "Condition unexpectedly admitted control U+\(control.unicodeScalars.first?.value ?? 0)."
            )
        }
    }

    func testTypedActionsEnforceExpressionLogAndCountBounds() throws {
        let expressionAtLimit = String(repeating: "x", count: 1_024)
        let logAtLimit = String(repeating: "l", count: 4_096)
        let capture = try DebuggerBreakpointExpressionCapture(
            label: "result",
            expression: expressionAtLimit
        )
        let template = try DebuggerBreakpointLogTemplate(
            fragments: [.literal(logAtLimit)]
        )

        XCTAssertNoThrow(
            try specification(
                actions: [
                    .evaluateTargetExpression(capture),
                    .log(template),
                ]
            )
        )
        XCTAssertThrowsError(
            try DebuggerBreakpointExpressionCapture(
                label: "result",
                expression: expressionAtLimit + "x"
            )
        )
        XCTAssertThrowsError(
            try DebuggerBreakpointLogTemplate(
                fragments: [.targetExpression(expressionAtLimit + "x")]
            )
        )
        XCTAssertThrowsError(
            try DebuggerBreakpointLogTemplate(
                fragments: [.literal(logAtLimit + "l")]
            )
        )
        XCTAssertNoThrow(
            try DebuggerBreakpointLogTemplate(
                fragments: Array(repeating: .targetExpression("x"), count: 32)
            )
        )
        XCTAssertThrowsError(
            try DebuggerBreakpointLogTemplate(
                fragments: Array(repeating: .targetExpression("x"), count: 33)
            )
        )
        XCTAssertThrowsError(
            try specification(
                actions: Array(repeating: .log(try DebuggerBreakpointLogTemplate(
                    fragments: [.literal("bounded")]
                )), count: 17)
            )
        )
    }

    func testAuthoredTextRemainsDataButControlBearingTextIsRejected() throws {
        let adversarial = "'\"`;/ marker=BEGIN QUJDREVGRw=="
        let log = try DebuggerBreakpointLogTemplate(
            fragments: [
                .literal(adversarial),
                .targetExpression("object.description"),
            ]
        )
        XCTAssertNoThrow(
            try specification(
                condition: "flag == 1 && text == \"safe\"",
                actions: [.log(log)]
            )
        )

        for control in ["\n", "\t", "\u{202D}", "\u{2066}"] {
            XCTAssertThrowsError(
                try DebuggerBreakpointLogTemplate(
                    fragments: [.literal("before\(control)after")]
                )
            )
            XCTAssertThrowsError(
                try DebuggerBreakpointExpressionCapture(
                    label: "value",
                    expression: "before\(control)after"
                )
            )
        }
    }

    func testCanonicalPersistenceContainsOnlyDurableAuthoringFacts() throws {
        let value = try specification(
            condition: "counter > 4",
            hitPolicy: .ignoreFirst(3),
            actions: [
                .log(try DebuggerBreakpointLogTemplate(
                    fragments: [.literal("counter="), .targetExpression("counter")]
                )),
            ],
            disposition: .continueAfterSuccessfulActions
        )
        let catalog = try DebuggerLogicalBreakpointCatalog(
            catalogID: UUID(),
            revision: 7,
            specifications: [value]
        )
        let encoded = try DebuggerLogicalBreakpointCanonicalCodec.encodeCatalog(catalog)
        let object = try JSONSerialization.jsonObject(with: encoded)
        let keys = allJSONKeys(in: object)

        for forbidden in [
            "runtimeAddress",
            "runtimeModuleInstanceID",
            "backendBreakpointID",
            "backendLocationID",
            "bindingID",
            "pid",
            "hitCount",
            "observedHitCount",
            "logRecords",
            "cleanupState",
        ] {
            XCTAssertFalse(keys.contains(forbidden), "Persisted runtime-only field: \(forbidden)")
        }

        var forged = try XCTUnwrap(object as? [String: Any])
        forged["runtimeAddress"] = 0x7fff_1234
        let forgedData = try JSONSerialization.data(
            withJSONObject: forged,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        XCTAssertThrowsError(
            try DebuggerLogicalBreakpointCanonicalCodec.decodeCatalog(forgedData)
        )
    }

    func testCanonicalDecodersRejectOversizedDataBeforeJSONParsing() {
        XCTAssertThrowsError(
            try DebuggerLogicalBreakpointCanonicalCodec.decodeSpecification(
                Data(repeating: 0x20, count: 16 * 1_024 + 1)
            )
        ) { error in
            XCTAssertEqual(
                error as? DebuggerLogicalBreakpointValidationError,
                .payloadTooLarge
            )
        }

        XCTAssertThrowsError(
            try DebuggerLogicalBreakpointCanonicalCodec.decodeCatalog(
                Data(repeating: 0x20, count: 8 * 1_024 * 1_024 + 8 * 1_024 + 1)
            )
        ) { error in
            XCTAssertEqual(
                error as? DebuggerLogicalBreakpointValidationError,
                .payloadTooLarge
            )
        }
    }

    private func specification(
        id: String = "99999999-9999-9999-9999-999999999999",
        target: DebuggerLogicalBreakpointTarget? = nil,
        condition: String? = nil,
        hitPolicy: DebuggerBreakpointHitPolicy = .always,
        actions: [DebuggerBreakpointAction] = [],
        disposition: DebuggerBreakpointDisposition = .stop
    ) throws -> DebuggerLogicalBreakpointSpecification {
        try DebuggerLogicalBreakpointSpecification(
            id: DebuggerLogicalBreakpointID(rawValue: UUID(uuidString: id)!),
            revision: DebuggerLogicalBreakpointRevision(validating: 1),
            enabled: true,
            target: target ?? .preferredAddress(
                owner: owner(),
                preferredVA: 0x1_0000_1000
            ),
            condition: condition,
            hitPolicy: hitPolicy,
            actions: actions,
            disposition: disposition
        )
    }

    private func owner() -> DebuggerWorkspaceImageOwnerSeal {
        DebuggerWorkspaceImageOwnerSeal(
            slot: .primary,
            binaryID: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
            artifactIdentity: try! MachOSliceArtifactIdentity(
                uuid: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
                rawCPUType: MachOConstants.cpuTypeARM64,
                rawCPUSubtype: 0,
                selectedSliceSHA256: String(repeating: "a", count: 64),
                selectedSliceByteCount: 0x4000
            )
        )
    }

    private func sourceFile(
        tablePath: DebuggerCanonicalSourceTablePath
    ) throws -> DebuggerCanonicalSourceFileIdentity {
        try DebuggerCanonicalSourceFileIdentity(
            debugArtifactUUID: UUID(uuidString: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD")!,
            debugArtifactMachOSHA256: String(repeating: "d", count: 64),
            debugArtifactMachOByteCount: 0x8000,
            lineProgramUnitOffset: 0x1234,
            fileTableIndex: 7,
            tablePath: tablePath
        )
    }

    private func roundTrip<Value: Codable & Equatable>(
        _ value: Value,
        as _: Value.Type
    ) throws -> Value {
        try JSONDecoder().decode(Value.self, from: JSONEncoder().encode(value))
    }

    private func allJSONKeys(in object: Any) -> Set<String> {
        if let dictionary = object as? [String: Any] {
            return Set(dictionary.keys).union(
                dictionary.values.reduce(into: Set<String>()) { result, value in
                    result.formUnion(allJSONKeys(in: value))
                }
            )
        }
        if let array = object as? [Any] {
            return array.reduce(into: Set<String>()) { result, value in
                result.formUnion(allJSONKeys(in: value))
            }
        }
        return []
    }
}

import XCTest
@testable import MacScope

final class DecompilerComparisonTests: XCTestCase {
    func testProjectionPreservesStructuredDivergenceInsteadOfCountAgreement() throws {
        let coordinate = makeCoordinate(slot: .primary)
        let projection = DecompilerComparisonProjection.project(
            coordinate: coordinate,
            expected: makeIdentity(matching: coordinate),
            native: makeSuccess(coordinate: coordinate, instructionStarts: [0x1000, 0x1004]),
            macScope: makeMacScopeInput(instructionStarts: [0x1000, 0x1008])
        )
        guard case let .ready(comparison) = projection else {
            return XCTFail("Expected a structured comparison")
        }
        let instructions = try XCTUnwrap(
            comparison.structural.categories.first { $0.category == .instructions }
        )
        XCTAssertEqual(instructions.counts.matchedCount, 1)
        XCTAssertEqual(instructions.counts.nativeOnlyCount, 1)
        XCTAssertEqual(instructions.counts.macScopeOnlyCount, 1)
        XCTAssertEqual(instructions.correspondence, .divergent)
    }

    func testProjectionPreservesEmptyAsNoComparableRecords() throws {
        let coordinate = makeCoordinate(slot: .primary)
        let projection = DecompilerComparisonProjection.project(
            coordinate: coordinate,
            expected: makeIdentity(matching: coordinate),
            native: makeSuccess(coordinate: coordinate, instructionStarts: []),
            macScope: makeMacScopeInput(instructionStarts: [])
        )
        guard case let .ready(comparison) = projection else {
            return XCTFail("Expected a structured comparison")
        }
        for category in comparison.structural.categories {
            XCTAssertEqual(category.coverage, .none)
            XCTAssertEqual(category.correspondence, .noComparableRecords)
        }
    }

    func testComparisonFailsClosedWhenEitherSemanticSourceIsUnavailable() {
        let coordinate = makeCoordinate(slot: .primary)
        let identity = makeIdentity(matching: coordinate)
        XCTAssertEqual(
            DecompilerComparisonProjection.project(
                coordinate: nil,
                expected: identity,
                native: nil,
                macScope: makeMacScopeInput(instructionStarts: [])
            ),
            .unavailable(.nativeUnavailable)
        )
        XCTAssertEqual(
            DecompilerComparisonProjection.project(
                coordinate: coordinate,
                expected: identity,
                native: makeSuccess(coordinate: coordinate, instructionStarts: []),
                macScope: nil
            ),
            .unavailable(.macScopeUnavailable)
        )
    }

    func testCollidingVirtualAddressesInDifferentImagesCannotShareComparisonCoordinate() {
        let primary = makeCoordinate(slot: .primary)
        let sibling = makeCoordinate(slot: ImageSlot(rawValue: 1))
        XCTAssertEqual(
            DecompilerComparisonProjection.project(
                coordinate: primary,
                expected: makeIdentity(matching: sibling),
                native: makeSuccess(coordinate: primary, instructionStarts: [0x1000]),
                macScope: makeMacScopeInput(instructionStarts: [0x1000])
            ),
            .unavailable(.coordinateMismatch)
        )
    }
}

private func makeCoordinate(slot: ImageSlot) -> NativeDecompilerPresentationCoordinate {
    NativeDecompilerPresentationCoordinate(
        imageSlot: slot,
        ownerBinaryID: slot == .primary
            ? UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
            : UUID(uuidString: "10000000-0000-0000-0000-000000000099")!,
        artifactUUID: slot == .primary
            ? UUID(uuidString: "20000000-0000-0000-0000-000000000002")!
            : UUID(uuidString: "20000000-0000-0000-0000-000000000099")!,
        imageID: slot == .primary ? "image:primary" : "image:sibling",
        functionID: "30000000-0000-0000-0000-000000000003",
        requestSHA256: String(repeating: slot == .primary ? "a" : "c", count: 64),
        analysisInputFingerprintSHA256: String(
            repeating: slot == .primary ? "b" : "d",
            count: 64
        )
    )
}

private func makeIdentity(
    matching coordinate: NativeDecompilerPresentationCoordinate
) -> DecompilerPresentationIdentity {
    DecompilerPresentationIdentity(
        imageSlot: coordinate.imageSlot,
        ownerBinaryID: coordinate.ownerBinaryID,
        artifactUUID: coordinate.artifactUUID,
        functionID: coordinate.functionID,
        analysisInputFingerprintSHA256: coordinate.analysisInputFingerprintSHA256
    )
}

private func makeMacScopeInput(
    instructionStarts: [UInt64]
) -> NativeDecompilerMacScopeComparisonInput {
    NativeDecompilerMacScopeComparisonInput(
        function: FunctionSummary(
            id: UUID(uuidString: "30000000-0000-0000-0000-000000000003")!,
            name: "fixture",
            startAddress: 0x1000,
            endAddress: 0x100c,
            confidence: 1
        ),
        instructionStarts: instructionStarts,
        basicBlocks: [],
        controlFlowEdges: [],
        directCallXRefs: []
    )
}

private func makeSuccess(
    coordinate: NativeDecompilerPresentationCoordinate,
    instructionStarts: [UInt64]
) -> NativeDecompilerWireSuccess {
    let result = NativeDecompilerWireStructuredResult(
        requestID: UUID(),
        requestSHA256: coordinate.requestSHA256,
        image: .init(
            imageID: coordinate.imageID,
            uuid: coordinate.artifactUUID,
            preferredLoadAddress: .init(0x1000)
        ),
        function: .init(
            functionID: coordinate.functionID,
            name: "fixture",
            entryAddress: .init(0x1000),
            endAddressExclusive: .init(0x100c)
        ),
        addressSpaces: [], types: [],
        instructions: instructionStarts.enumerated().map { index, address in
            .init(
                id: "instruction-\(index)", address: .init(address),
                bytes: Data([0x1f, 0x20, 0x03, 0xd5]), mnemonic: "nop", body: "",
                operationIDs: [], sourceRanges: []
            )
        },
        varnodes: [], operations: [], blocks: [], edges: [], ssaValues: [],
        ssaBindings: [], phis: [], memoryVersions: [], memoryPhis: [], memoryEffects: [],
        variables: [], calls: [], regions: [], tokens: [], warnings: []
    )
    return NativeDecompilerWireSuccess(
        availability: .init(
            available: true,
            reasonCode: "ready",
            runtimeIdentity: .init(
                backendID: "native", engineVersion: "1", engineRevision: "engine",
                wrapperVersion: "1", wrapperRevision: "wrapper",
                packageManifestSHA256: String(repeating: "e", count: 64),
                packageTreeSHA256: String(repeating: "f", count: 64),
                languageID: "AARCH64:LE:64:AppleSilicon", compilerSpecID: "default",
                targetProfileID: "apple-aarch64-pac-visible-clobber-v1",
                contextProfileSHA256: String(repeating: "0", count: 64)
            ),
            capabilities: .init(
                nativeDecompilerHeritage: true, completeRegisterSSA: true, memorySSA: true,
                recoveredVariables: true, recoveredTypes: true, structuredControlFlow: true,
                tokenizedPseudocode: true, imageQualifiedSourceRanges: true
            )
        ),
        result: result
    )
}

import XCTest
@testable import MacScope

final class NativeDecompilerComparisonNormalizerTests: XCTestCase {
    func testEqualCountsAtDifferentInstructionAddressesDiverge() throws {
        let authority = makeAuthority()
        let comparison = try NativeDecompilerComparisonNormalizer.compare(
            native: makeNativeResult(instructionStarts: [0x1000, 0x1004]),
            nativeAuthority: authority,
            expectedAuthority: authority,
            macScope: NativeDecompilerMacScopeComparisonInput(
                function: FunctionSummary(
                    id: UUID(uuidString: authority.functionID)!,
                    name: "fixture",
                    startAddress: 0x1000,
                    endAddress: 0x100c,
                    confidence: 1
                ),
                instructionStarts: [0x1000, 0x1008],
                basicBlocks: [],
                controlFlowEdges: [],
                directCallXRefs: []
            )
        )

        let instructions = try XCTUnwrap(
            comparison.categories.first { $0.category == .instructions }
        )
        XCTAssertEqual(instructions.counts.matchedCount, 1)
        XCTAssertEqual(instructions.counts.nativeOnlyCount, 1)
        XCTAssertEqual(instructions.counts.macScopeOnlyCount, 1)
        XCTAssertEqual(instructions.coverage, .complete)
        XCTAssertEqual(instructions.correspondence, .divergent)
        XCTAssertEqual(
            instructions.samples.nativeOnly,
            [.instruction(address: 0x1004)]
        )
        XCTAssertEqual(
            instructions.samples.macScopeOnly,
            [.instruction(address: 0x1008)]
        )
    }

    func testNormalizesNonemptyExclusiveBlockIntervals() throws {
        let comparison = try compare(
            nativeInstructions: [0x1000, 0x1004],
            nativeBlocks: [nativeBlock("b0", 0x1000, 0x1008)],
            macScopeInstructions: [0x1000, 0x1004],
            macScopeBlocks: [macScopeBlock(0x1000, 0x1008)]
        )
        let blocks = try category(.blocks, in: comparison)
        XCTAssertEqual(blocks.counts.matchedCount, 1)
        XCTAssertEqual(blocks.coverage, .complete)
        XCTAssertEqual(blocks.correspondence, .exact)
    }

    func testRejectsOverlappingBlockIntervalsAsUncomparable() throws {
        let comparison = try compare(
            nativeInstructions: [0x1000, 0x1004, 0x1008],
            nativeBlocks: [
                nativeBlock("b0", 0x1000, 0x1008),
                nativeBlock("b1", 0x1004, 0x100c),
            ],
            macScopeInstructions: [0x1000, 0x1004, 0x1008]
        )
        let blocks = try category(.blocks, in: comparison)
        XCTAssertEqual(blocks.counts.uncomparableNativeCount, 2)
        XCTAssertEqual(
            Set(blocks.samples.uncomparableNative.map(\.reason)),
            [.overlappingBlockInterval]
        )
    }

    func testRejectsInstructionMisalignedBlockIntervalsAsUncomparable() throws {
        let comparison = try compare(
            nativeInstructions: [0x1000, 0x1004, 0x1008],
            nativeBlocks: [nativeBlock("b0", 0x1002, 0x1008)],
            macScopeInstructions: [0x1000, 0x1004, 0x1008]
        )
        let blocks = try category(.blocks, in: comparison)
        XCTAssertEqual(blocks.counts.uncomparableNativeCount, 1)
        XCTAssertEqual(blocks.samples.uncomparableNative.first?.reason, .instructionMisalignment)
    }

    func testRejectsDuplicateNativeBlockIDsAsUncomparable() throws {
        let comparison = try compare(
            nativeInstructions: [0x1000, 0x1004, 0x1008],
            nativeBlocks: [
                nativeBlock("duplicate", 0x1000, 0x1004),
                nativeBlock("duplicate", 0x1004, 0x100c),
            ],
            macScopeInstructions: [0x1000, 0x1004, 0x1008]
        )
        let blocks = try category(.blocks, in: comparison)
        XCTAssertEqual(blocks.counts.uncomparableNativeCount, 2)
        XCTAssertEqual(
            Set(blocks.samples.uncomparableNative.map(\.reason)),
            [.duplicateBlockID]
        )
    }

    func testDoesNotFallBackToEntryOnlyComparison() throws {
        let comparison = try compare(
            nativeInstructions: [0x1000, 0x1004, 0x1008],
            nativeBlocks: [nativeBlock("b0", 0x1000, 0x1008)],
            macScopeInstructions: [0x1000, 0x1004, 0x1008],
            macScopeBlocks: [macScopeBlock(0x1000, 0x100c)]
        )
        let blocks = try category(.blocks, in: comparison)
        XCTAssertEqual(blocks.counts.matchedCount, 0)
        XCTAssertEqual(blocks.counts.nativeOnlyCount, 1)
        XCTAssertEqual(blocks.counts.macScopeOnlyCount, 1)
        XCTAssertEqual(blocks.correspondence, .divergent)
    }

    func testMapsEveryFrozenMacScopeAndNativeEdgeKind() throws {
        try assertExactEdgeMapping(
            macScopeEdges: [
                edge(0x1004, 0x1008, "branch"),
                edge(0x1004, 0x1008, "fallthrough"),
            ],
            nativeEdges: [
                nativeEdge("e0", "b0", "b1", 0x1008, .trueBranch),
                nativeEdge("e1", "b0", "b1", 0x1008, .falseBranch),
            ]
        )
        try assertExactEdgeMapping(
            macScopeEdges: [edge(0x1004, 0x1008, "branch")],
            nativeEdges: [nativeEdge("e0", "b0", "b1", 0x1008, .branch)]
        )
        try assertExactEdgeMapping(
            macScopeEdges: [edge(0x1004, 0x1008, "fallthrough")],
            nativeEdges: [nativeEdge("e0", "b0", "b1", 0x1008, .fallthrough)]
        )
        try assertExactEdgeMapping(
            macScopeEdges: [edge(0x1004, 0x1008, "switch")],
            nativeEdges: [nativeEdge("e0", "b0", "b1", 0x1008, .switchCase)]
        )
        try assertExactEdgeMapping(
            macScopeEdges: [edge(0x1004, 0x1008, "switch")],
            nativeEdges: [nativeEdge("e0", "b0", "b1", 0x1008, .switchDefault)]
        )
    }

    func testNormalizesExactDirectCalls() throws {
        let comparison = try compare(
            nativeInstructions: [0x1000, 0x1004],
            nativeCalls: [nativeCall("c0", .direct, 0x2000, [sourceRange(0x1004, 0x1008)])],
            macScopeInstructions: [0x1000, 0x1004],
            macScopeCalls: [XRef(id: UUID(), from: 0x1004, to: 0x2000, kind: XRefKind.call)]
        )
        let calls = try category(.calls, in: comparison)
        XCTAssertEqual(calls.counts.matchedCount, 1)
        XCTAssertEqual(calls.correspondence, .exact)
    }

    func testSpliceEdgesRemainUncomparableRatherThanInventingBranchFacts() throws {
        let comparison = try compare(
            nativeInstructions: [0x1000, 0x1004, 0x1008],
            nativeBlocks: [nativeBlock("b0", 0x1000, 0x1008), nativeBlock("b1", 0x1008, 0x100c)],
            nativeEdges: [nativeEdge("splice", "b0", "b1", 0x1008, .splice)],
            macScopeInstructions: [0x1000, 0x1004, 0x1008],
            macScopeBlocks: [macScopeBlock(0x1000, 0x1008), macScopeBlock(0x1008, 0x100c)],
            macScopeEdges: [edge(0x1004, 0x1008, "branch")]
        )
        let edges = try category(.edges, in: comparison)
        XCTAssertEqual(edges.counts.matchedCount, 0)
        XCTAssertEqual(edges.counts.nativeOnlyCount, 0)
        XCTAssertEqual(edges.counts.uncomparableNativeCount, 1)
        XCTAssertEqual(edges.samples.uncomparableNative.first?.reason, .unsupportedEdgeKind)
    }

    func testIndirectNativeCallsAreUncomparable() throws {
        let comparison = try compare(
            nativeInstructions: [0x1000],
            nativeCalls: [nativeCall("c0", .indirect, nil, [sourceRange(0x1000, 0x1004)])],
            macScopeInstructions: [0x1000]
        )
        let calls = try category(.calls, in: comparison)
        XCTAssertEqual(calls.counts.uncomparableNativeCount, 1)
        XCTAssertEqual(calls.samples.uncomparableNative.first?.reason, .indirectCall)
    }

    func testMissingCallTargetOrRangeIsUncomparable() throws {
        let comparison = try compare(
            nativeInstructions: [0x1000, 0x1004],
            nativeCalls: [
                nativeCall("missing-target", .direct, nil, [sourceRange(0x1000, 0x1004)]),
                nativeCall("missing-range", .direct, 0x2000, []),
            ],
            macScopeInstructions: [0x1000, 0x1004]
        )
        let calls = try category(.calls, in: comparison)
        XCTAssertEqual(calls.counts.uncomparableNativeCount, 2)
        XCTAssertEqual(
            Set(calls.samples.uncomparableNative.map(\.reason)),
            [.missingCallTarget, .missingCallSourceRange]
        )
    }

    func testAmbiguousNativeCallSourceRangeIsUncomparable() throws {
        let comparison = try compare(
            nativeInstructions: [0x1000, 0x1004],
            nativeCalls: [nativeCall("c0", .direct, 0x2000, [sourceRange(0x1000, 0x1008)])],
            macScopeInstructions: [0x1000, 0x1004]
        )
        let calls = try category(.calls, in: comparison)
        XCTAssertEqual(calls.counts.uncomparableNativeCount, 1)
        XCTAssertEqual(calls.samples.uncomparableNative.first?.reason, .ambiguousCallSourceRange)
    }

    func testMacScopeCallSourceMustBeUniqueInstructionStart() throws {
        let comparison = try compare(
            nativeInstructions: [0x1000],
            macScopeInstructions: [0x1000],
            macScopeCalls: [XRef(id: UUID(), from: 0x1002, to: 0x2000, kind: XRefKind.call)]
        )
        let calls = try category(.calls, in: comparison)
        XCTAssertEqual(calls.counts.uncomparableMacScopeCount, 1)
        XCTAssertEqual(calls.samples.uncomparableMacScope.first?.reason, .invalidCallSource)
    }

    func testCheckedComparableDenominatorRejectsOverflow() {
        XCTAssertThrowsError(
            try NativeDecompilerComparisonCounts(
                matchedCount: Int.max,
                nativeOnlyCount: 1,
                macScopeOnlyCount: 0,
                uncomparableNativeCount: 0,
                uncomparableMacScopeCount: 0
            )
        ) { error in
            XCTAssertEqual(error as? NativeDecompilerComparisonError, .countOverflow)
        }
    }

    func testCheckedQualificationDenominatorRejectsOverflow() {
        XCTAssertThrowsError(
            try NativeDecompilerComparisonCounts(
                matchedCount: Int.max,
                nativeOnlyCount: 0,
                macScopeOnlyCount: 0,
                uncomparableNativeCount: 1,
                uncomparableMacScopeCount: 0
            )
        ) { error in
            XCTAssertEqual(error as? NativeDecompilerComparisonError, .countOverflow)
        }
    }

    func testDuplicateRawRecordsCollapseBeforeCounting() throws {
        let result = try compare(
            nativeInstructions: [0x1000, 0x1000],
            macScopeInstructions: [0x1000, 0x1000]
        )
        XCTAssertEqual(try category(.instructions, in: result).counts.matchedCount, 1)
    }

    func testDuplicateUncomparableDiagnosticsCollapseBeforeQualificationCounting() throws {
        let instructionResult = try compare(
            nativeInstructions: [0x2000, 0x2000],
            macScopeInstructions: [0x2004, 0x2004]
        )
        let instructions = try category(.instructions, in: instructionResult)

        XCTAssertEqual(instructions.counts.uncomparableNativeCount, 1)
        XCTAssertEqual(instructions.counts.uncomparableMacScopeCount, 1)
        XCTAssertEqual(instructions.counts.qualificationDenominator, 2)
        XCTAssertEqual(instructions.samples.uncomparableNative.count, 1)
        XCTAssertEqual(instructions.samples.uncomparableMacScope.count, 1)

        let duplicateCall = nativeCall("missing-target", .direct, nil, [])
        let factResult = try compare(
            nativeInstructions: [0x1000],
            nativeCalls: [duplicateCall, duplicateCall],
            macScopeInstructions: [0x1000]
        )
        let calls = try category(.calls, in: factResult)
        XCTAssertEqual(calls.counts.uncomparableNativeCount, 1)
        XCTAssertEqual(calls.counts.qualificationDenominator, 1)
        XCTAssertEqual(calls.samples.uncomparableNative.count, 1)
    }

    func testFirstEightSamplesUseUnsignedAddressThenKindOrder() {
        let samples = NativeDecompilerComparisonSamples(
            nativeOnly: (0..<12).reversed().map { .instruction(address: UInt64($0)) },
            macScopeOnly: [],
            uncomparableNative: [],
            uncomparableMacScope: []
        )
        XCTAssertEqual(samples.nativeOnly, (0..<8).map { .instruction(address: UInt64($0)) })
    }

    func testEveryNonmatchedSampleClassIsDeduplicatedAndBoundedToEight() {
        let tuple = (0..<12).flatMap { value in
            [NativeDecompilerComparisonTupleSample.instruction(address: UInt64(value)),
             .instruction(address: UInt64(value))]
        }
        let incomparable = (0..<12).flatMap { value in
            [NativeDecompilerComparisonUncomparableSample(
                reason: .invalidRange,
                primarySafeAddress: UInt64(value),
                secondarySafeAddress: nil
            )]
        }
        let samples = NativeDecompilerComparisonSamples(
            nativeOnly: tuple,
            macScopeOnly: tuple,
            uncomparableNative: incomparable,
            uncomparableMacScope: incomparable
        )
        XCTAssertEqual(samples.nativeOnly.count, 8)
        XCTAssertEqual(samples.macScopeOnly.count, 8)
        XCTAssertEqual(samples.uncomparableNative.count, 8)
        XCTAssertEqual(samples.uncomparableMacScope.count, 8)
    }

    func testTupleSamplesUseOnlyClosedCasesUnsignedAddressesAndKindTags() {
        XCTAssertEqual(NativeDecompilerComparisonTupleSample.instruction(address: UInt64.max).kindTag, 0)
        XCTAssertEqual(
            NativeDecompilerComparisonTupleSample.edge(
                sourceBlockStart: 1,
                targetBlockStart: 2,
                kind: .switch
            ).kindTag,
            6
        )
    }

    func testUncomparableSamplesUseOnlyClosedReasonCodesAndTwoSafeAddresses() {
        let sample = NativeDecompilerComparisonUncomparableSample(
            reason: .ambiguousEdgeEndpoint,
            primarySafeAddress: 1,
            secondarySafeAddress: 2
        )
        XCTAssertEqual(sample.reason.rawValue, "ambiguousEdgeEndpoint")
        XCTAssertEqual(sample.primarySafeAddress, 1)
        XCTAssertEqual(sample.secondarySafeAddress, 2)
    }

    func testPartialCoverageCanHaveExactComparableCorrespondence() throws {
        let comparison = try compare(
            nativeInstructions: [0x1000, 0x2000],
            macScopeInstructions: [0x1000]
        )
        let instructions = try category(.instructions, in: comparison)
        XCTAssertEqual(instructions.coverage, .partial)
        XCTAssertEqual(instructions.correspondence, .exact)
    }

    func testPartialCoverageCanHaveDivergentComparableCorrespondence() throws {
        let comparison = try compare(
            nativeInstructions: [0x1000, 0x1004, 0x2000],
            macScopeInstructions: [0x1000, 0x1008]
        )
        let instructions = try category(.instructions, in: comparison)
        XCTAssertEqual(instructions.coverage, .partial)
        XCTAssertEqual(instructions.correspondence, .divergent)
    }

    func testOnlyUncomparableRecordsProduceNoneAndNoComparableRecords() throws {
        let comparison = try compare(nativeInstructions: [0x2000], macScopeInstructions: [])
        let instructions = try category(.instructions, in: comparison)
        XCTAssertEqual(instructions.coverage, .none)
        XCTAssertEqual(instructions.correspondence, .noComparableRecords)
    }

    func testEmptyEmptyProducesNoneAndNoComparableRecords() throws {
        let instructions = try category(.instructions, in: compare())
        XCTAssertEqual(instructions.coverage, .none)
        XCTAssertEqual(instructions.correspondence, .noComparableRecords)
    }

    func testDisplayNamesMnemonicsWhitespaceAndSymbolsDoNotAffectComparison() throws {
        var native = makeNativeResult(instructionStarts: [0x1000])
        native = makeNativeResult(
            instructionStarts: [0x1000],
            instructionMnemonic: "  MOV X0, X0  "
        )
        let comparison = try NativeDecompilerComparisonNormalizer.compare(
            native: native,
            nativeAuthority: makeAuthority(),
            expectedAuthority: makeAuthority(),
            macScope: makeMacScopeInput(instructionStarts: [0x1000], functionName: "renamed")
        )
        XCTAssertEqual(try category(.instructions, in: comparison).correspondence, .exact)
    }

    func testAuthorityMismatchIsNotComparable() {
        let expected = makeAuthority()
        let mismatched = NativeDecompilerComparisonAuthority(
            imageSlot: ImageSlot(rawValue: 1),
            ownerBinaryID: expected.ownerBinaryID,
            artifactUUID: expected.artifactUUID,
            functionID: expected.functionID,
            requestSchemaVersion: expected.requestSchemaVersion,
            requestSHA256: expected.requestSHA256,
            analysisInputFingerprintSHA256: expected.analysisInputFingerprintSHA256,
            targetProfileID: expected.targetProfileID,
            runtimeIdentity: expected.runtimeIdentity
        )
        XCTAssertThrowsError(
            try NativeDecompilerComparisonNormalizer.compare(
                native: makeNativeResult(instructionStarts: []),
                nativeAuthority: mismatched,
                expectedAuthority: expected,
                macScope: makeMacScopeInput()
            )
        ) { error in
            XCTAssertEqual(error as? NativeDecompilerComparisonError, .authorityMismatch)
        }
    }

    func testStructuredComparisonRetainsFullValidatedAuthority() throws {
        let authority = makeAuthority()
        let comparison = try NativeDecompilerComparisonNormalizer.compare(
            native: makeNativeResult(instructionStarts: [0x1000]),
            nativeAuthority: authority,
            expectedAuthority: authority,
            macScope: makeMacScopeInput(instructionStarts: [0x1000])
        )

        XCTAssertEqual(comparison.authority, authority)
    }

    func testAuthorityRejectsTargetProfileThatContradictsRuntimeIdentity() {
        let expected = makeAuthority()
        let contradictory = NativeDecompilerComparisonAuthority(
            imageSlot: expected.imageSlot,
            ownerBinaryID: expected.ownerBinaryID,
            artifactUUID: expected.artifactUUID,
            functionID: expected.functionID,
            requestSchemaVersion: expected.requestSchemaVersion,
            requestSHA256: expected.requestSHA256,
            analysisInputFingerprintSHA256: expected.analysisInputFingerprintSHA256,
            targetProfileID: "contradictory-profile",
            runtimeIdentity: expected.runtimeIdentity
        )

        XCTAssertThrowsError(
            try NativeDecompilerComparisonNormalizer.compare(
                native: makeNativeResult(instructionStarts: [0x1000]),
                nativeAuthority: contradictory,
                expectedAuthority: contradictory,
                macScope: makeMacScopeInput(instructionStarts: [0x1000])
            )
        ) { error in
            XCTAssertEqual(error as? NativeDecompilerComparisonError, .authorityMismatch)
        }
    }

    func testCancellationStopsEveryBoundedNormalizationPass() {
        XCTAssertThrowsError(
            try NativeDecompilerComparisonNormalizer.compare(
                native: makeNativeResult(instructionStarts: [0x1000]),
                nativeAuthority: makeAuthority(),
                expectedAuthority: makeAuthority(),
                macScope: makeMacScopeInput(instructionStarts: [0x1000]),
                isCancelled: { true }
            )
        ) { error in
            XCTAssertTrue(error is CancellationError)
        }
    }

    private func assertExactEdgeMapping(
        macScopeEdges: [ControlFlowEdge],
        nativeEdges: [NativeDecompilerWireEdgeRecord]
    ) throws {
        let comparison = try compare(
            nativeInstructions: [0x1000, 0x1004, 0x1008],
            nativeBlocks: [
                nativeBlock("b0", 0x1000, 0x1008),
                nativeBlock("b1", 0x1008, 0x100c),
            ],
            nativeEdges: nativeEdges,
            macScopeInstructions: [0x1000, 0x1004, 0x1008],
            macScopeBlocks: [
                macScopeBlock(0x1000, 0x1008),
                macScopeBlock(0x1008, 0x100c),
            ],
            macScopeEdges: macScopeEdges
        )
        let edges = try category(.edges, in: comparison)
        XCTAssertEqual(edges.counts.matchedCount, nativeEdges.count)
        XCTAssertEqual(edges.counts.nativeOnlyCount, 0)
        XCTAssertEqual(edges.counts.macScopeOnlyCount, 0)
        XCTAssertEqual(edges.correspondence, .exact)
    }
}

private func makeAuthority() -> NativeDecompilerComparisonAuthority {
    NativeDecompilerComparisonAuthority(
        imageSlot: .primary,
        ownerBinaryID: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
        artifactUUID: UUID(uuidString: "20000000-0000-0000-0000-000000000002")!,
        functionID: "30000000-0000-0000-0000-000000000003",
        requestSchemaVersion: 3,
        requestSHA256: String(repeating: "a", count: 64),
        analysisInputFingerprintSHA256: String(repeating: "b", count: 64),
        targetProfileID: "arm64-apple-macos",
        runtimeIdentity: NativeDecompilerRuntimeIdentity(
            backendID: "ghidra-native",
            engineVersion: "1",
            engineRevision: "engine",
            wrapperVersion: "1",
            wrapperRevision: "wrapper",
            packageManifestSHA256: String(repeating: "c", count: 64),
            packageTreeSHA256: String(repeating: "d", count: 64),
            languageID: "AARCH64:LE:64:v8A",
            compilerSpecID: "default",
            targetProfileID: "arm64-apple-macos",
            contextProfileSHA256: String(repeating: "e", count: 64)
        )
    )
}

private func compare(
    nativeInstructions: [UInt64] = [],
    nativeBlocks: [NativeDecompilerWireBlockRecord] = [],
    nativeEdges: [NativeDecompilerWireEdgeRecord] = [],
    nativeCalls: [NativeDecompilerWireCallRecord] = [],
    macScopeInstructions: [UInt64] = [],
    macScopeBlocks: [BasicBlockSummary] = [],
    macScopeEdges: [ControlFlowEdge] = [],
    macScopeCalls: [XRef] = []
) throws -> NativeDecompilerStructuredComparison {
    try NativeDecompilerComparisonNormalizer.compare(
        native: makeNativeResult(
            instructionStarts: nativeInstructions,
            blocks: nativeBlocks,
            edges: nativeEdges,
            calls: nativeCalls
        ),
        nativeAuthority: makeAuthority(),
        expectedAuthority: makeAuthority(),
        macScope: makeMacScopeInput(
            instructionStarts: macScopeInstructions,
            blocks: macScopeBlocks,
            edges: macScopeEdges,
            calls: macScopeCalls
        )
    )
}

private func category(
    _ category: NativeDecompilerComparisonCategory,
    in comparison: NativeDecompilerStructuredComparison
) throws -> NativeDecompilerComparisonCategoryResult {
    try XCTUnwrap(comparison.categories.first { $0.category == category })
}

private func makeMacScopeInput(
    instructionStarts: [UInt64] = [],
    blocks: [BasicBlockSummary] = [],
    edges: [ControlFlowEdge] = [],
    calls: [XRef] = [],
    functionName: String = "fixture"
) -> NativeDecompilerMacScopeComparisonInput {
    NativeDecompilerMacScopeComparisonInput(
        function: FunctionSummary(
            id: UUID(uuidString: makeAuthority().functionID)!,
            name: functionName,
            startAddress: 0x1000,
            endAddress: 0x100c,
            confidence: 1
        ),
        instructionStarts: instructionStarts,
        basicBlocks: blocks,
        controlFlowEdges: edges,
        directCallXRefs: calls
    )
}

private func makeNativeResult(
    instructionStarts: [UInt64],
    blocks: [NativeDecompilerWireBlockRecord] = [],
    edges: [NativeDecompilerWireEdgeRecord] = [],
    calls: [NativeDecompilerWireCallRecord] = [],
    instructionMnemonic: String = "nop"
) -> NativeDecompilerWireStructuredResult {
    let authority = makeAuthority()
    return NativeDecompilerWireStructuredResult(
        requestID: UUID(uuidString: "40000000-0000-0000-0000-000000000004")!,
        requestSHA256: authority.requestSHA256,
        image: NativeDecompilerWireImageIdentity(
            imageID: "image:primary",
            uuid: authority.artifactUUID,
            preferredLoadAddress: .init(0x1000)
        ),
        function: NativeDecompilerWireFunctionIdentity(
            functionID: authority.functionID,
            name: "fixture",
            entryAddress: .init(0x1000),
            endAddressExclusive: .init(0x100c)
        ),
        addressSpaces: [],
        types: [],
        instructions: instructionStarts.enumerated().map { index, address in
            NativeDecompilerWireInstructionRecord(
                id: "instruction-\(index)",
                address: .init(address),
                bytes: Data([0x1f, 0x20, 0x03, 0xd5]),
                mnemonic: instructionMnemonic,
                body: "",
                operationIDs: [],
                sourceRanges: []
            )
        },
        varnodes: [],
        operations: [],
        blocks: blocks,
        edges: edges,
        ssaValues: [],
        ssaBindings: [],
        phis: [],
        memoryVersions: [],
        memoryPhis: [],
        memoryEffects: [],
        variables: [],
        calls: calls,
        regions: [],
        tokens: [],
        warnings: []
    )
}

private func nativeBlock(
    _ id: String,
    _ start: UInt64,
    _ end: UInt64
) -> NativeDecompilerWireBlockRecord {
    NativeDecompilerWireBlockRecord(
        id: id,
        startAddress: .init(start),
        endAddressExclusive: .init(end),
        operationIDs: [],
        predecessorEdgeIDs: [],
        successorEdgeIDs: [],
        terminatorKind: .exit
    )
}

private func macScopeBlock(_ start: UInt64, _ end: UInt64) -> BasicBlockSummary {
    BasicBlockSummary(
        id: UUID(),
        functionID: UUID(uuidString: makeAuthority().functionID)!,
        startAddress: start,
        endAddress: end,
        instructionCount: 1
    )
}

private func edge(_ from: UInt64, _ to: UInt64, _ kind: String) -> ControlFlowEdge {
    ControlFlowEdge(id: UUID(), from: from, to: to, kind: kind)
}

private func nativeEdge(
    _ id: String,
    _ sourceBlockID: String,
    _ targetBlockID: String?,
    _ targetAddress: UInt64,
    _ kind: NativeDecompilerWireEdgeKind
) -> NativeDecompilerWireEdgeRecord {
    NativeDecompilerWireEdgeRecord(
        id: id,
        sourceBlockID: sourceBlockID,
        targetBlockID: targetBlockID,
        targetAddress: .init(targetAddress),
        kind: kind,
        operationID: nil
    )
}

private func sourceRange(
    _ start: UInt64,
    _ end: UInt64
) -> NativeDecompilerWireSourceRange {
    NativeDecompilerWireSourceRange(
        imageID: "image:primary",
        startAddress: .init(start),
        endAddressExclusive: .init(end)
    )
}

private func nativeCall(
    _ id: String,
    _ kind: NativeDecompilerWireCallKind,
    _ target: UInt64?,
    _ ranges: [NativeDecompilerWireSourceRange]
) -> NativeDecompilerWireCallRecord {
    NativeDecompilerWireCallRecord(
        id: id,
        operationID: "operation-\(id)",
        kind: kind,
        targetAddress: target.map(NativeDecompilerWireUInt64.init),
        targetSymbol: nil,
        prototypeTypeID: nil,
        argumentVariableIDs: [],
        resultVariableID: nil,
        sourceRanges: ranges
    )
}

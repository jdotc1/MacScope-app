import Foundation

struct NativeDecompilerComparisonAuthority: Equatable, Sendable {
    let imageSlot: ImageSlot
    let ownerBinaryID: UUID
    let artifactUUID: UUID
    let functionID: String
    let requestSchemaVersion: UInt32
    let requestSHA256: String
    let analysisInputFingerprintSHA256: String
    let targetProfileID: String
    let runtimeIdentity: NativeDecompilerRuntimeIdentity
}

struct NativeDecompilerMacScopeComparisonInput: Equatable, Sendable {
    let function: FunctionSummary
    let instructionStarts: [UInt64]
    let basicBlocks: [BasicBlockSummary]
    let controlFlowEdges: [ControlFlowEdge]
    let directCallXRefs: [XRef]
}

enum NativeDecompilerComparisonCategory: String, CaseIterable, Hashable, Sendable {
    case instructions
    case blocks
    case edges
    case calls
}

enum NativeDecompilerCommonEdgeKind: UInt8, Comparable, Hashable, Sendable {
    case unconditional
    case `fallthrough`
    case conditionalTaken
    case conditionalFallthrough
    case `switch`

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

enum NativeDecompilerComparisonCoverage: String, Sendable {
    case complete
    case partial
    case none
}

enum NativeDecompilerComparisonCorrespondence: String, Sendable {
    case exact
    case divergent
    case noComparableRecords
}

enum NativeDecompilerComparisonError: Error, Equatable, Sendable {
    case authorityMismatch
    case invalidFunctionRange
    case countOverflow
}

enum NativeDecompilerComparisonTupleSample: Hashable, Sendable {
    case instruction(address: UInt64)
    case block(startAddress: UInt64, endAddressExclusive: UInt64)
    case edge(
        sourceBlockStart: UInt64,
        targetBlockStart: UInt64,
        kind: NativeDecompilerCommonEdgeKind
    )
    case call(sourceInstructionStart: UInt64, targetAddress: UInt64)

    var unsignedAddressSortKey: [UInt64] {
        switch self {
        case let .instruction(address):
            [address]
        case let .block(startAddress, endAddressExclusive):
            [startAddress, endAddressExclusive]
        case let .edge(sourceBlockStart, targetBlockStart, _):
            [sourceBlockStart, targetBlockStart]
        case let .call(sourceInstructionStart, targetAddress):
            [sourceInstructionStart, targetAddress]
        }
    }

    var kindTag: UInt8 {
        switch self {
        case .instruction: 0
        case .block: 1
        case let .edge(_, _, kind): 2 + kind.rawValue
        case .call: 8
        }
    }
}

enum NativeDecompilerComparisonUncomparableReason: String, CaseIterable, Hashable, Sendable {
    case invalidOwnership
    case conflictingOwnership
    case invalidRange
    case outOfFunctionRange
    case overlappingBlockInterval
    case instructionMisalignment
    case duplicateBlockID
    case externalEdgeEndpoint
    case missingEdgeEndpoint
    case ambiguousEdgeEndpoint
    case inconsistentEdgeEndpoint
    case unsupportedEdgeKind
    case indirectCall
    case missingCallTarget
    case missingCallSourceRange
    case ambiguousCallSourceRange
    case invalidCallSource
}

struct NativeDecompilerComparisonUncomparableSample: Hashable, Sendable {
    let reason: NativeDecompilerComparisonUncomparableReason
    let primarySafeAddress: UInt64?
    let secondarySafeAddress: UInt64?
}

struct NativeDecompilerComparisonSamples: Equatable, Sendable {
    static let maximumPerClass = 8

    let nativeOnly: [NativeDecompilerComparisonTupleSample]
    let macScopeOnly: [NativeDecompilerComparisonTupleSample]
    let uncomparableNative: [NativeDecompilerComparisonUncomparableSample]
    let uncomparableMacScope: [NativeDecompilerComparisonUncomparableSample]

    init(
        nativeOnly: [NativeDecompilerComparisonTupleSample],
        macScopeOnly: [NativeDecompilerComparisonTupleSample],
        uncomparableNative: [NativeDecompilerComparisonUncomparableSample],
        uncomparableMacScope: [NativeDecompilerComparisonUncomparableSample]
    ) {
        self.nativeOnly = Self.firstEightTuples(nativeOnly)
        self.macScopeOnly = Self.firstEightTuples(macScopeOnly)
        self.uncomparableNative = Self.firstEightUncomparable(uncomparableNative)
        self.uncomparableMacScope = Self.firstEightUncomparable(uncomparableMacScope)
    }

    private static func firstEightTuples(
        _ input: [NativeDecompilerComparisonTupleSample]
    ) -> [NativeDecompilerComparisonTupleSample] {
        Array(Set(input).sorted {
            if $0.unsignedAddressSortKey != $1.unsignedAddressSortKey {
                return $0.unsignedAddressSortKey.lexicographicallyPrecedes(
                    $1.unsignedAddressSortKey
                )
            }
            return $0.kindTag < $1.kindTag
        }.prefix(maximumPerClass))
    }

    private static func firstEightUncomparable(
        _ input: [NativeDecompilerComparisonUncomparableSample]
    ) -> [NativeDecompilerComparisonUncomparableSample] {
        Array(Set(input).sorted {
            if $0.primarySafeAddress != $1.primarySafeAddress {
                switch ($0.primarySafeAddress, $1.primarySafeAddress) {
                case let (.some(lhs), .some(rhs)): return lhs < rhs
                case (.some, .none): return true
                case (.none, .some): return false
                case (.none, .none): break
                }
            }
            if $0.secondarySafeAddress != $1.secondarySafeAddress {
                switch ($0.secondarySafeAddress, $1.secondarySafeAddress) {
                case let (.some(lhs), .some(rhs)): return lhs < rhs
                case (.some, .none): return true
                case (.none, .some): return false
                case (.none, .none): break
                }
            }
            return $0.reason.rawValue < $1.reason.rawValue
        }.prefix(maximumPerClass))
    }
}

struct NativeDecompilerComparisonCounts: Equatable, Sendable {
    let matchedCount: Int
    let nativeOnlyCount: Int
    let macScopeOnlyCount: Int
    let uncomparableNativeCount: Int
    let uncomparableMacScopeCount: Int
    let comparableUnionDenominator: Int
    let qualificationDenominator: Int

    init(
        matchedCount: Int,
        nativeOnlyCount: Int,
        macScopeOnlyCount: Int,
        uncomparableNativeCount: Int,
        uncomparableMacScopeCount: Int
    ) throws {
        let inputs = [
            matchedCount,
            nativeOnlyCount,
            macScopeOnlyCount,
            uncomparableNativeCount,
            uncomparableMacScopeCount,
        ]
        guard inputs.allSatisfy({ $0 >= 0 }) else {
            throw NativeDecompilerComparisonError.countOverflow
        }

        let firstComparable = matchedCount.addingReportingOverflow(nativeOnlyCount)
        guard !firstComparable.overflow else {
            throw NativeDecompilerComparisonError.countOverflow
        }
        let comparable = firstComparable.partialValue.addingReportingOverflow(macScopeOnlyCount)
        guard !comparable.overflow else {
            throw NativeDecompilerComparisonError.countOverflow
        }
        let firstQualification = comparable.partialValue.addingReportingOverflow(
            uncomparableNativeCount
        )
        guard !firstQualification.overflow else {
            throw NativeDecompilerComparisonError.countOverflow
        }
        let qualification = firstQualification.partialValue.addingReportingOverflow(
            uncomparableMacScopeCount
        )
        guard !qualification.overflow else {
            throw NativeDecompilerComparisonError.countOverflow
        }

        self.matchedCount = matchedCount
        self.nativeOnlyCount = nativeOnlyCount
        self.macScopeOnlyCount = macScopeOnlyCount
        self.uncomparableNativeCount = uncomparableNativeCount
        self.uncomparableMacScopeCount = uncomparableMacScopeCount
        comparableUnionDenominator = comparable.partialValue
        qualificationDenominator = qualification.partialValue
    }
}

struct NativeDecompilerComparisonCategoryResult: Equatable, Sendable {
    let category: NativeDecompilerComparisonCategory
    let counts: NativeDecompilerComparisonCounts
    let coverage: NativeDecompilerComparisonCoverage
    let correspondence: NativeDecompilerComparisonCorrespondence
    let samples: NativeDecompilerComparisonSamples
}

struct NativeDecompilerStructuredComparison: Equatable, Sendable {
    let normalizerID: String
    let authority: NativeDecompilerComparisonAuthority
    let categories: [NativeDecompilerComparisonCategoryResult]
}

enum NativeDecompilerComparisonNormalizer {
    static let normalizerID = "NativeDecompilerComparisonNormalizer.v1"

    static func compare(
        native: NativeDecompilerWireStructuredResult,
        nativeAuthority: NativeDecompilerComparisonAuthority,
        expectedAuthority: NativeDecompilerComparisonAuthority,
        macScope: NativeDecompilerMacScopeComparisonInput,
        isCancelled: @Sendable () -> Bool = { Task.isCancelled }
    ) throws -> NativeDecompilerStructuredComparison {
        guard nativeAuthority == expectedAuthority,
              nativeAuthority.targetProfileID == nativeAuthority.runtimeIdentity.targetProfileID,
              native.requestSHA256 == nativeAuthority.requestSHA256,
              native.image.uuid == nativeAuthority.artifactUUID,
              native.function.functionID == nativeAuthority.functionID,
              functionIDsMatch(macScope.function.id, nativeAuthority.functionID)
        else {
            throw NativeDecompilerComparisonError.authorityMismatch
        }

        let nativeStart = native.function.entryAddress.value
        let nativeEnd = native.function.endAddressExclusive.value
        guard nativeStart < nativeEnd,
              macScope.function.startAddress < macScope.function.endAddress,
              nativeStart == macScope.function.startAddress,
              nativeEnd == macScope.function.endAddress
        else {
            throw NativeDecompilerComparisonError.invalidFunctionRange
        }

        try checkCancellation(isCancelled)
        let nativeInstructions = normalizeInstructionStarts(
            native.instructions.map(\.address.value),
            functionRange: nativeStart..<nativeEnd
        )
        try checkCancellation(isCancelled)
        let macScopeInstructions = normalizeInstructionStarts(
            macScope.instructionStarts,
            functionRange: nativeStart..<nativeEnd
        )
        try checkCancellation(isCancelled)

        let nativeOnly = nativeInstructions.comparable.subtracting(macScopeInstructions.comparable)
        let macScopeOnly = macScopeInstructions.comparable.subtracting(nativeInstructions.comparable)
        let matched = nativeInstructions.comparable.intersection(macScopeInstructions.comparable)
        let instructionCounts = try NativeDecompilerComparisonCounts(
            matchedCount: matched.count,
            nativeOnlyCount: nativeOnly.count,
            macScopeOnlyCount: macScopeOnly.count,
            uncomparableNativeCount: Set(nativeInstructions.uncomparable).count,
            uncomparableMacScopeCount: Set(macScopeInstructions.uncomparable).count
        )

        try checkCancellation(isCancelled)
        let nativeBlocks = normalizeNativeBlocks(
            native.blocks,
            instructionStarts: nativeInstructions.comparable,
            functionRange: nativeStart..<nativeEnd
        )
        let macScopeBlocks = normalizeMacScopeBlocks(
            macScope.basicBlocks,
            functionID: macScope.function.id,
            instructionStarts: macScopeInstructions.comparable,
            functionRange: nativeStart..<nativeEnd
        )
        try checkCancellation(isCancelled)

        let nativeEdges = normalizeNativeEdges(
            native.edges,
            blocks: nativeBlocks,
            functionRange: nativeStart..<nativeEnd
        )
        let macScopeEdges = normalizeMacScopeEdges(
            macScope.controlFlowEdges,
            blocks: macScopeBlocks,
            functionRange: nativeStart..<nativeEnd
        )
        try checkCancellation(isCancelled)

        let nativeCalls = normalizeNativeCalls(
            native.calls,
            imageID: native.image.imageID,
            instructionStarts: nativeInstructions.comparable
        )
        let macScopeCalls = normalizeMacScopeCalls(
            macScope.directCallXRefs,
            instructionStarts: macScopeInstructions.comparable
        )
        try checkCancellation(isCancelled)

        var categories = [
            categoryResult(
                category: .instructions,
                counts: instructionCounts,
                nativeOnly: nativeOnly.map { .instruction(address: $0) },
                macScopeOnly: macScopeOnly.map { .instruction(address: $0) },
                uncomparableNative: nativeInstructions.uncomparable,
                uncomparableMacScope: macScopeInstructions.uncomparable
            ),
        ]
        categories.append(try blockCategory(native: nativeBlocks, macScope: macScopeBlocks))
        categories.append(try edgeCategory(native: nativeEdges, macScope: macScopeEdges))
        categories.append(try callCategory(native: nativeCalls, macScope: macScopeCalls))
        return NativeDecompilerStructuredComparison(
            normalizerID: normalizerID,
            authority: nativeAuthority,
            categories: categories
        )
    }

    private struct NormalizedInstructions {
        let comparable: Set<UInt64>
        let uncomparable: [NativeDecompilerComparisonUncomparableSample]
    }

    private struct BlockFact: Hashable {
        let start: UInt64
        let end: UInt64
    }

    private struct ResolvedBlock {
        let fact: BlockFact
        let identifier: String?
        let finalInstructionStart: UInt64
    }

    private enum BlockValidation {
        case valid(finalInstructionStart: UInt64)
        case invalid(NativeDecompilerComparisonUncomparableReason)
    }

    private struct NormalizedBlocks {
        let comparable: Set<BlockFact>
        let resolved: [ResolvedBlock]
        let nativeIDMultiplicity: [String: Int]
        let uncomparable: [NativeDecompilerComparisonUncomparableSample]
    }

    private struct EdgeFact: Hashable {
        let sourceBlockStart: UInt64
        let targetBlockStart: UInt64
        let kind: NativeDecompilerCommonEdgeKind
    }

    private struct CallFact: Hashable {
        let sourceInstructionStart: UInt64
        let targetAddress: UInt64
        let direct: Bool
    }

    private struct NormalizedFacts<Fact: Hashable> {
        let comparable: Set<Fact>
        let uncomparable: [NativeDecompilerComparisonUncomparableSample]
    }

    private static func normalizeInstructionStarts(
        _ starts: [UInt64],
        functionRange: Range<UInt64>
    ) -> NormalizedInstructions {
        var comparable = Set<UInt64>()
        var uncomparable = [NativeDecompilerComparisonUncomparableSample]()
        for address in starts {
            guard functionRange.contains(address) else {
                uncomparable.append(
                    NativeDecompilerComparisonUncomparableSample(
                        reason: .outOfFunctionRange,
                        primarySafeAddress: address,
                        secondarySafeAddress: nil
                    )
                )
                continue
            }
            comparable.insert(address)
        }
        return NormalizedInstructions(
            comparable: comparable,
            uncomparable: uncomparable
        )
    }

    private static func normalizeNativeBlocks(
        _ records: [NativeDecompilerWireBlockRecord],
        instructionStarts: Set<UInt64>,
        functionRange: Range<UInt64>
    ) -> NormalizedBlocks {
        let multiplicity = Dictionary(grouping: records, by: \.id).mapValues(\.count)
        var candidates = [ResolvedBlock]()
        var uncomparable = [NativeDecompilerComparisonUncomparableSample]()

        for record in records {
            let start = record.startAddress.value
            let end = record.endAddressExclusive.value
            if multiplicity[record.id, default: 0] != 1 {
                uncomparable.append(uncomparableSample(.duplicateBlockID, start, end))
                continue
            }
            switch validateBlock(
                start: start,
                end: end,
                instructionStarts: instructionStarts,
                functionRange: functionRange
            ) {
            case let .valid(finalInstructionStart):
                candidates.append(ResolvedBlock(
                    fact: BlockFact(start: start, end: end),
                    identifier: record.id,
                    finalInstructionStart: finalInstructionStart
                ))
            case let .invalid(reason):
                uncomparable.append(uncomparableSample(reason, start, end))
            }
        }
        return finishBlocks(
            candidates,
            nativeIDMultiplicity: multiplicity,
            uncomparable: uncomparable
        )
    }

    private static func normalizeMacScopeBlocks(
        _ records: [BasicBlockSummary],
        functionID: UUID,
        instructionStarts: Set<UInt64>,
        functionRange: Range<UInt64>
    ) -> NormalizedBlocks {
        var candidates = [ResolvedBlock]()
        var uncomparable = [NativeDecompilerComparisonUncomparableSample]()

        for record in records {
            let start = record.startAddress
            let end = record.endAddress
            guard record.functionID == functionID else {
                uncomparable.append(uncomparableSample(.invalidOwnership, start, end))
                continue
            }
            switch validateBlock(
                start: start,
                end: end,
                instructionStarts: instructionStarts,
                functionRange: functionRange
            ) {
            case let .valid(finalInstructionStart):
                candidates.append(ResolvedBlock(
                    fact: BlockFact(start: start, end: end),
                    identifier: nil,
                    finalInstructionStart: finalInstructionStart
                ))
            case let .invalid(reason):
                uncomparable.append(uncomparableSample(reason, start, end))
            }
        }
        return finishBlocks(
            candidates,
            nativeIDMultiplicity: [:],
            uncomparable: uncomparable
        )
    }

    private static func validateBlock(
        start: UInt64,
        end: UInt64,
        instructionStarts: Set<UInt64>,
        functionRange: Range<UInt64>
    ) -> BlockValidation {
        guard start < end else { return .invalid(.invalidRange) }
        guard functionRange.contains(start), end <= functionRange.upperBound else {
            return .invalid(.outOfFunctionRange)
        }
        let instructionEnds = Set(instructionStarts.compactMap { address -> UInt64? in
            let (end, overflow) = address.addingReportingOverflow(4)
            return overflow ? nil : end
        })
        guard instructionStarts.contains(start),
              end == functionRange.upperBound
                || instructionStarts.contains(end)
                || instructionEnds.contains(end)
        else {
            return .invalid(.instructionMisalignment)
        }
        guard let finalInstructionStart = instructionStarts
            .filter({ $0 >= start && $0 < end })
            .max()
        else {
            return .invalid(.instructionMisalignment)
        }
        return .valid(finalInstructionStart: finalInstructionStart)
    }

    private static func finishBlocks(
        _ candidates: [ResolvedBlock],
        nativeIDMultiplicity: [String: Int],
        uncomparable initialUncomparable: [NativeDecompilerComparisonUncomparableSample]
    ) -> NormalizedBlocks {
        var overlapping = Set<Int>()
        for lhsIndex in candidates.indices {
            for rhsIndex in candidates.indices where rhsIndex > lhsIndex {
                let lhs = candidates[lhsIndex].fact
                let rhs = candidates[rhsIndex].fact
                guard lhs != rhs else { continue }
                if lhs.start < rhs.end, rhs.start < lhs.end {
                    overlapping.insert(lhsIndex)
                    overlapping.insert(rhsIndex)
                }
            }
        }

        var uncomparable = initialUncomparable
        var resolved = [ResolvedBlock]()
        for (candidateIndex, candidate) in candidates.enumerated() {
            if overlapping.contains(candidateIndex) {
                uncomparable.append(uncomparableSample(
                    .overlappingBlockInterval,
                    candidate.fact.start,
                    candidate.fact.end
                ))
            } else {
                resolved.append(candidate)
            }
        }
        return NormalizedBlocks(
            comparable: Set(resolved.map(\.fact)),
            resolved: resolved,
            nativeIDMultiplicity: nativeIDMultiplicity,
            uncomparable: uncomparable
        )
    }

    private static func normalizeNativeEdges(
        _ records: [NativeDecompilerWireEdgeRecord],
        blocks: NormalizedBlocks,
        functionRange: Range<UInt64>
    ) -> NormalizedFacts<EdgeFact> {
        let blocksByID = Dictionary(grouping: blocks.resolved.compactMap { block in
            block.identifier.map { ($0, block) }
        }, by: { $0.0 })
        var comparable = Set<EdgeFact>()
        var uncomparable = [NativeDecompilerComparisonUncomparableSample]()

        for record in records {
            let targetAddress = record.targetAddress.value
            guard let kind = commonNativeEdgeKind(record.kind) else {
                uncomparable.append(uncomparableSample(.unsupportedEdgeKind, nil, targetAddress))
                continue
            }
            let sourceCandidates = blocksByID[record.sourceBlockID, default: []].map(\.1)
            guard sourceCandidates.count == 1 else {
                let reason: NativeDecompilerComparisonUncomparableReason =
                    blocks.nativeIDMultiplicity[record.sourceBlockID, default: 0] > 1
                    ? .ambiguousEdgeEndpoint : .missingEdgeEndpoint
                uncomparable.append(uncomparableSample(reason, nil, targetAddress))
                continue
            }
            guard let targetID = record.targetBlockID else {
                let reason: NativeDecompilerComparisonUncomparableReason =
                    functionRange.contains(targetAddress) ? .missingEdgeEndpoint : .externalEdgeEndpoint
                uncomparable.append(uncomparableSample(
                    reason,
                    sourceCandidates[0].fact.start,
                    targetAddress
                ))
                continue
            }
            let targetCandidates = blocksByID[targetID, default: []].map(\.1)
            guard targetCandidates.count == 1 else {
                let reason: NativeDecompilerComparisonUncomparableReason =
                    blocks.nativeIDMultiplicity[targetID, default: 0] > 1
                    ? .ambiguousEdgeEndpoint
                    : (functionRange.contains(targetAddress) ? .missingEdgeEndpoint : .externalEdgeEndpoint)
                uncomparable.append(uncomparableSample(
                    reason,
                    sourceCandidates[0].fact.start,
                    targetAddress
                ))
                continue
            }
            let source = sourceCandidates[0]
            let target = targetCandidates[0]
            guard target.fact.start == targetAddress else {
                uncomparable.append(uncomparableSample(
                    .inconsistentEdgeEndpoint,
                    source.fact.start,
                    targetAddress
                ))
                continue
            }
            comparable.insert(EdgeFact(
                sourceBlockStart: source.fact.start,
                targetBlockStart: target.fact.start,
                kind: kind
            ))
        }
        return NormalizedFacts(comparable: comparable, uncomparable: uncomparable)
    }

    private static func normalizeMacScopeEdges(
        _ records: [ControlFlowEdge],
        blocks: NormalizedBlocks,
        functionRange: Range<UInt64>
    ) -> NormalizedFacts<EdgeFact> {
        let pairedSources = Set(records.filter { $0.kind == "branch" }.map(\.from))
            .intersection(records.filter { $0.kind == "fallthrough" }.map(\.from))
        var comparable = Set<EdgeFact>()
        var uncomparable = [NativeDecompilerComparisonUncomparableSample]()

        for record in records {
            if record.kind == XRefKind.call { continue }
            guard let kind = commonMacScopeEdgeKind(record.kind, paired: pairedSources.contains(record.from)) else {
                uncomparable.append(uncomparableSample(.unsupportedEdgeKind, record.from, record.to))
                continue
            }
            let sources = Set(
                blocks.resolved
                    .filter { $0.finalInstructionStart == record.from }
                    .map(\.fact)
            )
            let targets = Set(
                blocks.resolved
                    .filter { $0.fact.start == record.to }
                    .map(\.fact)
            )
            guard sources.count == 1 else {
                let reason: NativeDecompilerComparisonUncomparableReason =
                    functionRange.contains(record.from)
                    ? (sources.isEmpty ? .missingEdgeEndpoint : .ambiguousEdgeEndpoint)
                    : .externalEdgeEndpoint
                uncomparable.append(uncomparableSample(reason, record.from, record.to))
                continue
            }
            guard targets.count == 1 else {
                let reason: NativeDecompilerComparisonUncomparableReason =
                    functionRange.contains(record.to)
                    ? (targets.isEmpty ? .missingEdgeEndpoint : .ambiguousEdgeEndpoint)
                    : .externalEdgeEndpoint
                uncomparable.append(uncomparableSample(reason, record.from, record.to))
                continue
            }
            comparable.insert(EdgeFact(
                sourceBlockStart: sources.first!.start,
                targetBlockStart: targets.first!.start,
                kind: kind
            ))
        }
        return NormalizedFacts(comparable: comparable, uncomparable: uncomparable)
    }

    private static func normalizeNativeCalls(
        _ records: [NativeDecompilerWireCallRecord],
        imageID: String,
        instructionStarts: Set<UInt64>
    ) -> NormalizedFacts<CallFact> {
        var comparable = Set<CallFact>()
        var uncomparable = [NativeDecompilerComparisonUncomparableSample]()
        for record in records {
            guard record.kind == .direct else {
                uncomparable.append(uncomparableSample(.indirectCall, nil, record.targetAddress?.value))
                continue
            }
            guard let targetAddress = record.targetAddress?.value else {
                uncomparable.append(uncomparableSample(.missingCallTarget, nil, nil))
                continue
            }
            guard !record.sourceRanges.isEmpty else {
                uncomparable.append(uncomparableSample(.missingCallSourceRange, nil, targetAddress))
                continue
            }
            guard record.sourceRanges.allSatisfy({
                $0.imageID == imageID && $0.startAddress.value < $0.endAddressExclusive.value
            }) else {
                uncomparable.append(uncomparableSample(.invalidCallSource, nil, targetAddress))
                continue
            }
            let candidates = instructionStarts.filter { address in
                record.sourceRanges.contains {
                    $0.startAddress.value <= address && address < $0.endAddressExclusive.value
                }
            }
            guard candidates.count == 1, let source = candidates.first else {
                let reason: NativeDecompilerComparisonUncomparableReason = candidates.isEmpty
                    ? .invalidCallSource : .ambiguousCallSourceRange
                uncomparable.append(uncomparableSample(reason, candidates.min(), targetAddress))
                continue
            }
            comparable.insert(CallFact(
                sourceInstructionStart: source,
                targetAddress: targetAddress,
                direct: true
            ))
        }
        return NormalizedFacts(comparable: comparable, uncomparable: uncomparable)
    }

    private static func normalizeMacScopeCalls(
        _ records: [XRef],
        instructionStarts: Set<UInt64>
    ) -> NormalizedFacts<CallFact> {
        var comparable = Set<CallFact>()
        var uncomparable = [NativeDecompilerComparisonUncomparableSample]()
        for record in records where record.kind == XRefKind.call {
            guard instructionStarts.contains(record.from) else {
                uncomparable.append(uncomparableSample(.invalidCallSource, record.from, record.to))
                continue
            }
            comparable.insert(CallFact(
                sourceInstructionStart: record.from,
                targetAddress: record.to,
                direct: true
            ))
        }
        return NormalizedFacts(comparable: comparable, uncomparable: uncomparable)
    }

    private static func commonNativeEdgeKind(
        _ kind: NativeDecompilerWireEdgeKind
    ) -> NativeDecompilerCommonEdgeKind? {
        switch kind {
        case .branch: .unconditional
        case .fallthrough: .fallthrough
        case .trueBranch: .conditionalTaken
        case .falseBranch: .conditionalFallthrough
        case .switchCase, .switchDefault: .switch
        case .splice: nil
        }
    }

    private static func commonMacScopeEdgeKind(
        _ kind: String,
        paired: Bool
    ) -> NativeDecompilerCommonEdgeKind? {
        switch kind {
        case "branch": paired ? .conditionalTaken : .unconditional
        case "fallthrough": paired ? .conditionalFallthrough : .fallthrough
        case "switch": .switch
        default: nil
        }
    }

    private static func blockCategory(
        native: NormalizedBlocks,
        macScope: NormalizedBlocks
    ) throws -> NativeDecompilerComparisonCategoryResult {
        try factCategory(
            category: .blocks,
            native: NormalizedFacts(comparable: native.comparable, uncomparable: native.uncomparable),
            macScope: NormalizedFacts(comparable: macScope.comparable, uncomparable: macScope.uncomparable),
            sample: { .block(startAddress: $0.start, endAddressExclusive: $0.end) }
        )
    }

    private static func edgeCategory(
        native: NormalizedFacts<EdgeFact>,
        macScope: NormalizedFacts<EdgeFact>
    ) throws -> NativeDecompilerComparisonCategoryResult {
        try factCategory(category: .edges, native: native, macScope: macScope) {
            .edge(
                sourceBlockStart: $0.sourceBlockStart,
                targetBlockStart: $0.targetBlockStart,
                kind: $0.kind
            )
        }
    }

    private static func callCategory(
        native: NormalizedFacts<CallFact>,
        macScope: NormalizedFacts<CallFact>
    ) throws -> NativeDecompilerComparisonCategoryResult {
        try factCategory(category: .calls, native: native, macScope: macScope) {
            .call(sourceInstructionStart: $0.sourceInstructionStart, targetAddress: $0.targetAddress)
        }
    }

    private static func factCategory<Fact: Hashable>(
        category: NativeDecompilerComparisonCategory,
        native: NormalizedFacts<Fact>,
        macScope: NormalizedFacts<Fact>,
        sample: (Fact) -> NativeDecompilerComparisonTupleSample
    ) throws -> NativeDecompilerComparisonCategoryResult {
        let nativeOnly = native.comparable.subtracting(macScope.comparable)
        let macScopeOnly = macScope.comparable.subtracting(native.comparable)
        let matched = native.comparable.intersection(macScope.comparable)
        return categoryResult(
            category: category,
            counts: try NativeDecompilerComparisonCounts(
                matchedCount: matched.count,
                nativeOnlyCount: nativeOnly.count,
                macScopeOnlyCount: macScopeOnly.count,
                uncomparableNativeCount: Set(native.uncomparable).count,
                uncomparableMacScopeCount: Set(macScope.uncomparable).count
            ),
            nativeOnly: nativeOnly.map(sample),
            macScopeOnly: macScopeOnly.map(sample),
            uncomparableNative: native.uncomparable,
            uncomparableMacScope: macScope.uncomparable
        )
    }

    private static func uncomparableSample(
        _ reason: NativeDecompilerComparisonUncomparableReason,
        _ primary: UInt64?,
        _ secondary: UInt64?
    ) -> NativeDecompilerComparisonUncomparableSample {
        NativeDecompilerComparisonUncomparableSample(
            reason: reason,
            primarySafeAddress: primary,
            secondarySafeAddress: secondary
        )
    }

    private static func categoryResult(
        category: NativeDecompilerComparisonCategory,
        counts: NativeDecompilerComparisonCounts,
        nativeOnly: [NativeDecompilerComparisonTupleSample],
        macScopeOnly: [NativeDecompilerComparisonTupleSample],
        uncomparableNative: [NativeDecompilerComparisonUncomparableSample],
        uncomparableMacScope: [NativeDecompilerComparisonUncomparableSample]
    ) -> NativeDecompilerComparisonCategoryResult {
        let coverage: NativeDecompilerComparisonCoverage
        if counts.qualificationDenominator > 0,
           counts.uncomparableNativeCount == 0,
           counts.uncomparableMacScopeCount == 0 {
            coverage = .complete
        } else if counts.comparableUnionDenominator > 0 {
            coverage = .partial
        } else {
            coverage = .none
        }

        let correspondence: NativeDecompilerComparisonCorrespondence
        if counts.comparableUnionDenominator > 0,
           counts.nativeOnlyCount == 0,
           counts.macScopeOnlyCount == 0 {
            correspondence = .exact
        } else if counts.nativeOnlyCount > 0 || counts.macScopeOnlyCount > 0 {
            correspondence = .divergent
        } else {
            correspondence = .noComparableRecords
        }

        return NativeDecompilerComparisonCategoryResult(
            category: category,
            counts: counts,
            coverage: coverage,
            correspondence: correspondence,
            samples: NativeDecompilerComparisonSamples(
                nativeOnly: nativeOnly,
                macScopeOnly: macScopeOnly,
                uncomparableNative: uncomparableNative,
                uncomparableMacScope: uncomparableMacScope
            )
        )
    }

    private static func functionIDsMatch(_ macScopeID: UUID, _ nativeID: String) -> Bool {
        if let nativeUUID = UUID(uuidString: nativeID) {
            return nativeUUID == macScopeID
        }
        return macScopeID.uuidString == nativeID
    }

    private static func checkCancellation(
        _ isCancelled: @Sendable () -> Bool
    ) throws {
        if isCancelled() {
            throw CancellationError()
        }
    }
}

import CryptoKit
import Foundation
@testable import MacScope


struct Phase2ProductionProtocolFixtureContentIdentity: Equatable, Hashable, Sendable {
    let id: String
    let version: Int
    let sha256: String
}

enum Phase2ProductionProtocolFixtureStage: String, CaseIterable, Hashable, Sendable {
    case registryProjection = "registry-projection"
    case requestEncoding = "request-encoding"
    case toolCallAssembly = "tool-call-assembly"
    case strictJSONParsing = "strict-json-parsing"
    case streamDecoding = "stream-decoding"
    case finalDecoding = "final-decoding"
    case promptCompilation = "prompt-compilation"
    case artifactCanonicalization = "artifact-canonicalization"
    case inferenceBoundary = "inference-boundary"
}

enum Phase2ProductionProtocolFixtureCode: String, CaseIterable, Hashable, Sendable {
    case accepted
    case exactBytesMatched = "exact-bytes-matched"
    case identityChanged = "identity-changed"
    case cancelledWithoutSemanticOutput = "cancelled-without-semantic-output"
    case invalidAtomicMetadata = "invalid-atomic-metadata"
    case atomicMetadataMismatch = "atomic-metadata-mismatch"
    case invalidArguments = "invalid-arguments"
    case unknownFunctionHandlePair = "unknown-function-handle-pair"
    case duplicateCallID = "duplicate-call-id"
    case duplicateHandle = "duplicate-handle"
    case noncontiguousIndices = "noncontiguous-indices"
    case invalidIndex = "invalid-index"
    case duplicateJSONKey = "duplicate-json-key"
    case trailingJSONBytes = "trailing-json-bytes"
    case JSONDepthLimitExceeded = "json-depth-limit-exceeded"
    case JSONTokenLimitExceeded = "json-token-limit-exceeded"
    case JSONMemberLimitExceeded = "json-member-limit-exceeded"
    case unsupportedCapability = "unsupported-capability"
    case unsupportedFinishReason = "unsupported-finish-reason"
    case invalidUsage = "invalid-usage"
    case recordAfterTerminal = "record-after-terminal"
    case invalidFinalSchema = "invalid-final-schema"
    case invalidEvidenceID = "invalid-evidence-id"
    case duplicateEvidenceID = "duplicate-evidence-id"
    case unknownEvidenceID = "unknown-evidence-id"
    case finalTextLimitExceeded = "final-text-limit-exceeded"
    case finalReasonLimitExceeded = "final-reason-limit-exceeded"
    case malformedFinalEnvelope = "malformed-final-envelope"
    case finalEnvelopeLimitExceeded = "final-envelope-limit-exceeded"
    case projectDataPreserved = "project-data-preserved"
    case streamContentLimitExceeded = "stream-content-limit-exceeded"
    case inferenceEventLimitExceeded = "inference-event-limit-exceeded"
    case inferenceCumulativeEventLimitExceeded = "inference-cumulative-event-limit-exceeded"
    case unavailableComponent = "unavailable-component"
    case executionFailed = "execution-failed"
}

enum Phase2ProductionProtocolFixtureRecipe: String, CaseIterable, Hashable, Sendable {
    case toolSingleWorkspaceSummary = "tool.single.workspace-summary"
    case toolSingleSelectionExplain = "tool.single.selection-explain"
    case toolSingleFunctionReview = "tool.single.function-review"
    case toolMulticallTwoOrdered = "tool.multicall.two-ordered"
    case toolMulticallThreeOrdered = "tool.multicall.three-ordered"
    case toolMulticallInterleaved = "tool.multicall.interleaved"
    case toolCallIDNonUUID = "tool.call-id.non-uuid"
    case toolAtomicIDDelayed = "tool.atomic.id-delayed"
    case toolAtomicTypeDelayed = "tool.atomic.type-delayed"
    case toolAtomicNameDelayed = "tool.atomic.name-delayed"
    case toolAtomicLaterOmission = "tool.atomic.later-omission"
    case toolAtomicIDMutation = "tool.atomic.id-mutation"
    case toolAtomicTypeMutation = "tool.atomic.type-mutation"
    case toolAtomicNameMutation = "tool.atomic.name-mutation"
    case toolArgumentsFragmented = "tool.arguments.fragmented"
    case toolSchemaNameHandlePairing = "tool.schema-name-handle-pairing"
    case toolRegistryOrder = "tool.registry-order"
    case toolArgumentMissingRequired = "tool.argument.missing-required"
    case toolArgumentUnknown = "tool.argument.unknown"
    case toolArgumentDuplicate = "tool.argument.duplicate"
    case toolArgumentWrongType = "tool.argument.wrong-type"
    case toolArgumentMalformed = "tool.argument.malformed"
    case toolArgumentTrailing = "tool.argument.trailing"
    case toolProposalUnofferedName = "tool.proposal.unoffered-name"
    case toolProposalInventedHandle = "tool.proposal.invented-handle"
    case toolProposalRepeatedHandle = "tool.proposal.repeated-handle"
    case toolProposalDuplicateCallID = "tool.proposal.duplicate-call-id"
    case toolProposalSparseIndex = "tool.proposal.sparse-index"
    case toolProposalOutOfRangeIndex = "tool.proposal.out-of-range-index"
    case JSONOrdinaryRecursiveDuplicate = "json.ordinary.recursive-duplicate"
    case JSONUsageRecursiveDuplicate = "json.usage.recursive-duplicate"
    case JSONOrdinaryTrailing = "json.ordinary.trailing"
    case JSONUsageTrailing = "json.usage.trailing"
    case JSONSSEDepthMaximum = "json.sse.depth-maximum"
    case JSONSSEDepthPlusOne = "json.sse.depth-plus-one"
    case JSONArgumentsDepthMaximum = "json.arguments.depth-maximum"
    case JSONArgumentsDepthPlusOne = "json.arguments.depth-plus-one"
    case JSONFinalDepthMaximum = "json.final.depth-maximum"
    case JSONFinalDepthPlusOne = "json.final.depth-plus-one"
    case JSONSSETokensMaximum = "json.sse.tokens-maximum"
    case JSONSSETokensPlusOne = "json.sse.tokens-plus-one"
    case JSONArgumentsTokensMaximum = "json.arguments.tokens-maximum"
    case JSONArgumentsTokensPlusOne = "json.arguments.tokens-plus-one"
    case JSONFinalTokensMaximum = "json.final.tokens-maximum"
    case JSONFinalTokensPlusOne = "json.final.tokens-plus-one"
    case JSONSSEMembersMaximum = "json.sse.members-maximum"
    case JSONSSEMembersPlusOne = "json.sse.members-plus-one"
    case JSONArgumentsMembersMaximum = "json.arguments.members-maximum"
    case JSONArgumentsMembersPlusOne = "json.arguments.members-plus-one"
    case JSONFinalMembersMaximum = "json.final.members-maximum"
    case JSONFinalMembersPlusOne = "json.final.members-plus-one"
    case toolOutputContent = "tool.output.content"
    case toolOutputFinalAnswer = "tool.output.final-answer"
    case toolFinishReasonWrong = "tool.finish-reason.wrong"
    case toolUsageIncomplete = "tool.usage.incomplete"
    case toolRecordAfterTerminal = "tool.record.after-terminal"
    case toolCancellationPartial = "tool.cancellation.partial"
    case requestToolSelectionByteFixture = "request.tool-selection.byte-fixture"
    case requestFinalizationByteFixture = "request.finalization.byte-fixture"
    case finalAnswer = "final.answer"
    case finalInsufficientEvidence = "final.insufficient-evidence"
    case finalEvidenceIDLowercase = "final.evidence-id.lowercase"
    case finalEvidenceIDMixedCase = "final.evidence-id.mixed-case"
    case finalEvidenceIDBraced = "final.evidence-id.braced"
    case finalEvidenceIDHyphenless = "final.evidence-id.hyphenless"
    case finalEvidenceIDPadded = "final.evidence-id.padded"
    case finalEvidenceIDOtherParseable = "final.evidence-id.other-parseable"
    case finalFieldUnknown = "final.field.unknown"
    case finalFieldDuplicate = "final.field.duplicate"
    case finalVariantMixed = "final.variant.mixed"
    case finalCitationBad = "final.citation.bad"
    case finalCitationDuplicate = "final.citation.duplicate"
    case finalCitationUnallowed = "final.citation.unallowed"
    case finalUnicode = "final.unicode"
    case finalLongOutput = "final.long-output"
    case finalTruncation = "final.truncation"
    case finalPromptInjectionAsData = "final.prompt-injection-as-data"
    case finalToolCall = "final.tool-call"
    case identityPromptByteDrift = "identity.prompt-byte-drift"
    case identityRegistryDescriptionDrift = "identity.registry-description-drift"
    case identityRegistryOrderDrift = "identity.registry-order-drift"
    case identitySchemaSemanticDrift = "identity.schema-semantic-drift"
    case identitySchemaSetVersionDrift = "identity.schema-set-version-drift"
    case identityProtocolVersionDrift = "identity.protocol-version-drift"
    case identityProbeCatalogDrift = "identity.probe-catalog-drift"
    case limitPreviewDeltaMaximum = "limit.preview-delta-maximum"
    case limitPreviewDeltaPlusOne = "limit.preview-delta-plus-one"
    case limitPreviewCumulativeMaximum = "limit.preview-cumulative-maximum"
    case limitPreviewCumulativePlusOne = "limit.preview-cumulative-plus-one"
    case limitAnswerTextMaximum = "limit.answer-text-maximum"
    case limitAnswerTextPlusOne = "limit.answer-text-plus-one"
    case limitReasonMaximum = "limit.reason-maximum"
    case limitReasonPlusOne = "limit.reason-plus-one"
    case limitFinalEnvelopeMaximum = "limit.final-envelope-maximum"
    case limitFinalEnvelopePlusOne = "limit.final-envelope-plus-one"
    case limitEventMaximum = "limit.event-maximum"
    case limitEventPlusOne = "limit.event-plus-one"
    case limitCumulativeEventMaximum = "limit.cumulative-event-maximum"
    case limitCumulativeEventPlusOne = "limit.cumulative-event-plus-one"
}

struct Phase2ProductionProtocolFixtureEntry: Equatable, Sendable {
    let probeID: String
    let fixtureID: Phase2ProductionProtocolFixtureID
    let recipe: Phase2ProductionProtocolFixtureRecipe
    let expectedOutcome: Phase2ProductionProtocolExpectedOutcome
    let expectedStage: Phase2ProductionProtocolFixtureStage
    let expectedCode: Phase2ProductionProtocolFixtureCode
    let subcaseCount: Int
    let inputDigests: [String]
    let generationParameters: [String]
    let identity: Phase2ProductionProtocolFixtureContentIdentity

    fileprivate init(
        probe: Phase2ProductionProtocolProbe,
        recipe: Phase2ProductionProtocolFixtureRecipe,
        blueprint: Phase2ProductionProtocolFixtureBlueprint
    ) {
        probeID = probe.id
        fixtureID = probe.fixtureID
        self.recipe = recipe
        expectedOutcome = probe.expectedOutcome
        expectedStage = recipe.expectedStage
        expectedCode = recipe.expectedCode
        subcaseCount = blueprint.subcaseCount
        inputDigests = blueprint.inputs.map(phase2FixtureSHA256)
        generationParameters = blueprint.generationParameters
        identity = .init(
            id: probe.fixtureID.rawValue,
            version: 1,
            sha256: phase2FixtureDigest([
                "expected_code": recipe.expectedCode.rawValue,
                "expected_outcome": probe.expectedOutcome.rawValue,
                "expected_stage": recipe.expectedStage.rawValue,
                "fixture_id": probe.fixtureID.rawValue,
                "generation_parameters": blueprint.generationParameters.joined(separator: "\u{1f}"),
                "input_digests": inputDigests.joined(separator: "\u{1f}"),
                "probe_id": probe.id,
                "runner_identity": blueprint.runnerIdentity,
                "subcase_count": String(blueprint.subcaseCount),
                "version": "1",
            ])
        )
    }
}

struct Phase2ProductionProtocolFixtureCorpus: Equatable, Sendable {
    static let standard = makeStandard()

    let entries: [Phase2ProductionProtocolFixtureEntry]
    let identity: Phase2ProductionProtocolFixtureContentIdentity

    private init(entries: [Phase2ProductionProtocolFixtureEntry]) {
        self.entries = entries
        identity = .init(
            id: "phase2.r1.deterministic-fixture-corpus.v1",
            version: 1,
            sha256: phase2FixtureDigest([
                "entry_identities": entries.map(\.identity.sha256).joined(separator: "\u{1f}"),
                "id": "phase2.r1.deterministic-fixture-corpus.v1",
                "version": "1",
            ])
        )
    }

    func entry(fixtureID rawValue: String) -> Phase2ProductionProtocolFixtureEntry? {
        entries.first { $0.fixtureID.rawValue == rawValue }
    }

    func entry(probeID: String) -> Phase2ProductionProtocolFixtureEntry? {
        entries.first { $0.probeID == probeID }
    }

    private static func makeStandard() -> Self {
        let probes = Phase2ProductionProtocolProbeCatalog().probes
        precondition(probes.count == 99)
        precondition(Phase2ProductionProtocolFixtureRecipe.allCases.count == probes.count)
        let entries = zip(probes, Phase2ProductionProtocolFixtureRecipe.allCases).map { probe, recipe in
            precondition(probe.id == recipe.rawValue)
            return Phase2ProductionProtocolFixtureEntry(
                probe: probe,
                recipe: recipe,
                blueprint: Phase2ProductionProtocolFixtureExecutor.blueprint(for: recipe)
            )
        }
        precondition(Set(entries.map(\.fixtureID)).count == entries.count)
        return .init(entries: entries)
    }
}

extension Phase2ProductionProtocolFixtureRecipe {
    /// The probe catalog owns the frozen verdict. Recipes derive it by their one-to-one probe ID
    /// instead of maintaining a second 99-case outcome table that could drift from the catalog.
    var expectedOutcome: Phase2ProductionProtocolExpectedOutcome {
        guard let probe = Phase2ProductionProtocolProbeCatalog().probes.first(where: {
            $0.id == rawValue
        }) else {
            preconditionFailure("fixture recipe must map to exactly one frozen protocol probe")
        }
        return probe.expectedOutcome
    }

    var expectedStage: Phase2ProductionProtocolFixtureStage {
        switch self {
        case .toolRegistryOrder:
            .registryProjection
        case .toolSingleWorkspaceSummary, .toolSingleSelectionExplain, .toolSingleFunctionReview,
             .toolMulticallTwoOrdered, .toolMulticallThreeOrdered, .toolMulticallInterleaved,
             .toolCallIDNonUUID, .toolAtomicIDDelayed, .toolAtomicTypeDelayed,
             .toolAtomicNameDelayed, .toolAtomicLaterOmission, .toolAtomicIDMutation,
             .toolAtomicTypeMutation, .toolAtomicNameMutation, .toolArgumentsFragmented,
             .toolSchemaNameHandlePairing, .toolArgumentMissingRequired, .toolArgumentUnknown,
             .toolArgumentDuplicate, .toolArgumentWrongType, .toolArgumentMalformed,
             .toolArgumentTrailing, .toolProposalUnofferedName, .toolProposalInventedHandle,
             .toolProposalRepeatedHandle, .toolProposalDuplicateCallID, .toolProposalSparseIndex,
             .toolProposalOutOfRangeIndex:
            .toolCallAssembly
        case .JSONOrdinaryRecursiveDuplicate, .JSONUsageRecursiveDuplicate,
             .JSONOrdinaryTrailing, .JSONUsageTrailing, .JSONSSEDepthMaximum,
             .JSONSSEDepthPlusOne, .JSONArgumentsDepthMaximum, .JSONArgumentsDepthPlusOne,
             .JSONSSETokensMaximum, .JSONSSETokensPlusOne,
             .JSONArgumentsTokensMaximum, .JSONArgumentsTokensPlusOne,
             .JSONSSEMembersMaximum, .JSONSSEMembersPlusOne,
             .JSONArgumentsMembersMaximum, .JSONArgumentsMembersPlusOne:
            .strictJSONParsing
        case .toolOutputContent, .toolOutputFinalAnswer, .toolFinishReasonWrong,
             .toolUsageIncomplete, .toolRecordAfterTerminal, .finalToolCall,
             .limitPreviewDeltaMaximum, .limitPreviewDeltaPlusOne,
             .limitPreviewCumulativeMaximum, .limitPreviewCumulativePlusOne:
            .streamDecoding
        case .toolCancellationPartial, .limitEventMaximum, .limitEventPlusOne,
             .limitCumulativeEventMaximum, .limitCumulativeEventPlusOne:
            .inferenceBoundary
        case .requestToolSelectionByteFixture, .requestFinalizationByteFixture:
            .requestEncoding
        case .finalAnswer, .finalInsufficientEvidence, .finalEvidenceIDLowercase,
             .finalEvidenceIDMixedCase, .finalEvidenceIDBraced, .finalEvidenceIDHyphenless,
             .finalEvidenceIDPadded, .finalEvidenceIDOtherParseable, .finalFieldUnknown,
             .finalFieldDuplicate, .finalVariantMixed, .finalCitationBad,
             .finalCitationDuplicate, .finalCitationUnallowed, .finalUnicode,
             .finalLongOutput, .finalTruncation, .limitAnswerTextMaximum,
             .limitAnswerTextPlusOne, .limitReasonMaximum, .limitReasonPlusOne,
             .limitFinalEnvelopeMaximum, .limitFinalEnvelopePlusOne,
             .JSONFinalDepthMaximum, .JSONFinalDepthPlusOne,
             .JSONFinalTokensMaximum, .JSONFinalTokensPlusOne,
             .JSONFinalMembersMaximum, .JSONFinalMembersPlusOne:
            .finalDecoding
        case .finalPromptInjectionAsData:
            .promptCompilation
        case .identityPromptByteDrift, .identityRegistryDescriptionDrift,
             .identityRegistryOrderDrift, .identitySchemaSemanticDrift,
             .identitySchemaSetVersionDrift, .identityProtocolVersionDrift,
             .identityProbeCatalogDrift:
            .artifactCanonicalization
        }
    }

    var expectedCode: Phase2ProductionProtocolFixtureCode {
        switch self {
        case .toolAtomicIDMutation, .toolAtomicTypeMutation, .toolAtomicNameMutation:
            .atomicMetadataMismatch
        case .toolArgumentMissingRequired, .toolArgumentUnknown, .toolArgumentDuplicate,
             .toolArgumentWrongType, .toolArgumentMalformed, .toolArgumentTrailing:
            .invalidArguments
        case .toolProposalUnofferedName:
            .invalidAtomicMetadata
        case .toolProposalInventedHandle:
            .unknownFunctionHandlePair
        case .toolProposalRepeatedHandle:
            .duplicateHandle
        case .toolProposalDuplicateCallID:
            .duplicateCallID
        case .toolProposalSparseIndex:
            .noncontiguousIndices
        case .toolProposalOutOfRangeIndex:
            .invalidIndex
        case .JSONOrdinaryRecursiveDuplicate, .JSONUsageRecursiveDuplicate:
            .duplicateJSONKey
        case .JSONOrdinaryTrailing, .JSONUsageTrailing:
            .trailingJSONBytes
        case .JSONSSEDepthPlusOne, .JSONArgumentsDepthPlusOne, .JSONFinalDepthPlusOne:
            .JSONDepthLimitExceeded
        case .JSONSSETokensPlusOne, .JSONArgumentsTokensPlusOne, .JSONFinalTokensPlusOne:
            .JSONTokenLimitExceeded
        case .JSONSSEMembersPlusOne, .JSONArgumentsMembersPlusOne, .JSONFinalMembersPlusOne:
            .JSONMemberLimitExceeded
        case .toolOutputContent, .toolOutputFinalAnswer, .finalToolCall:
            .unsupportedCapability
        case .toolFinishReasonWrong:
            .unsupportedFinishReason
        case .toolUsageIncomplete:
            .invalidUsage
        case .toolRecordAfterTerminal:
            .recordAfterTerminal
        case .toolCancellationPartial:
            .cancelledWithoutSemanticOutput
        case .requestToolSelectionByteFixture, .requestFinalizationByteFixture:
            .exactBytesMatched
        case .finalEvidenceIDLowercase, .finalEvidenceIDMixedCase, .finalEvidenceIDBraced,
             .finalEvidenceIDHyphenless, .finalEvidenceIDPadded,
             .finalEvidenceIDOtherParseable, .finalCitationBad:
            .invalidEvidenceID
        case .finalFieldUnknown, .finalFieldDuplicate, .finalVariantMixed:
            .invalidFinalSchema
        case .finalCitationDuplicate:
            .duplicateEvidenceID
        case .finalCitationUnallowed:
            .unknownEvidenceID
        case .finalLongOutput, .limitAnswerTextPlusOne:
            .finalTextLimitExceeded
        case .limitReasonPlusOne:
            .finalReasonLimitExceeded
        case .finalTruncation:
            .malformedFinalEnvelope
        case .finalPromptInjectionAsData:
            .projectDataPreserved
        case .identityPromptByteDrift, .identityRegistryDescriptionDrift,
             .identityRegistryOrderDrift, .identitySchemaSemanticDrift,
             .identitySchemaSetVersionDrift, .identityProtocolVersionDrift,
             .identityProbeCatalogDrift:
            .identityChanged
        case .limitPreviewDeltaPlusOne, .limitPreviewCumulativePlusOne:
            .streamContentLimitExceeded
        case .limitFinalEnvelopePlusOne:
            .finalEnvelopeLimitExceeded
        case .limitEventPlusOne:
            .inferenceEventLimitExceeded
        case .limitCumulativeEventPlusOne:
            .inferenceCumulativeEventLimitExceeded
        case .toolSingleWorkspaceSummary, .toolSingleSelectionExplain,
             .toolSingleFunctionReview, .toolMulticallTwoOrdered,
             .toolMulticallThreeOrdered, .toolMulticallInterleaved,
             .toolCallIDNonUUID, .toolAtomicIDDelayed, .toolAtomicTypeDelayed,
             .toolAtomicNameDelayed, .toolAtomicLaterOmission, .toolArgumentsFragmented,
             .toolSchemaNameHandlePairing, .toolRegistryOrder,
             .JSONSSEDepthMaximum, .JSONArgumentsDepthMaximum, .JSONFinalDepthMaximum,
             .JSONSSETokensMaximum, .JSONArgumentsTokensMaximum, .JSONFinalTokensMaximum,
             .JSONSSEMembersMaximum, .JSONArgumentsMembersMaximum, .JSONFinalMembersMaximum,
             .finalAnswer, .finalInsufficientEvidence, .finalUnicode,
             .limitPreviewDeltaMaximum, .limitPreviewCumulativeMaximum,
             .limitAnswerTextMaximum, .limitReasonMaximum, .limitFinalEnvelopeMaximum,
             .limitEventMaximum, .limitCumulativeEventMaximum:
            .accepted
        }
    }
}

func phase2FixtureSHA256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

func phase2FixtureDigest(_ fields: [String: String]) -> String {
    var data = Data()
    for key in fields.keys.sorted(by: { $0.utf8.lexicographicallyPrecedes($1.utf8) }) {
        let keyData = Data(key.utf8)
        let valueData = Data(fields[key]!.utf8)
        data.append(Data("k\(keyData.count):".utf8))
        data.append(keyData)
        data.append(Data("v\(valueData.count):".utf8))
        data.append(valueData)
    }
    return phase2FixtureSHA256(data)
}

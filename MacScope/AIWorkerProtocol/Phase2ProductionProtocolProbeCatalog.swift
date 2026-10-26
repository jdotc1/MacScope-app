import CryptoKit
import Foundation

struct Phase2ProductionArtifactIdentity: Equatable, Hashable, Sendable {
    let id: String
    let version: Int
    let sha256: String
}

private indirect enum Phase2ProductionProbeCanonicalValue: Sendable {
    case number(String)
    case string(String)
    case array([Self])
    case object([String: Self])

    func lengthFramedBytes() -> Data {
        switch self {
        case .number(let value):
            return frame("i", Data(value.utf8))
        case .string(let value):
            return frame("s", Data(value.utf8))
        case .array(let values):
            return frame("a", values.reduce(into: Data()) { $0.append($1.lengthFramedBytes()) })
        case .object(let object):
            var payload = Data()
            for key in object.keys.sorted(by: { $0.utf8.lexicographicallyPrecedes($1.utf8) }) {
                payload.append(Self.string(key).lengthFramedBytes())
                payload.append(object[key]!.lengthFramedBytes())
            }
            return frame("o", payload)
        }
    }

    private func frame(_ type: Character, _ payload: Data) -> Data {
        var data = Data("\(type)\(payload.count):".utf8)
        data.append(payload)
        return data
    }
}

enum Phase2ProductionProtocolProbeCategory: String, Equatable, Sendable {
    case toolSelection = "tool-selection"
    case strictJSON = "strict-json"
    case finalization
    case limits
    case identity
    case request
}

/// Closed fixture verdict vocabulary. F4C compares an observed categorical result with this
/// value; it does not reinterpret free-form text as a pass or certification decision.
enum Phase2ProductionProtocolExpectedOutcome: String, CaseIterable, Equatable, Sendable {
    case accepted
    case rejected
    case exactBytesMatched = "exact-bytes-matched"
    case identityChanged = "identity-changed"
    case cancelledWithoutSemanticOutput = "cancelled-without-semantic-output"
}

/// Stable payload-free binding to one deterministic fixture owned by the future F4C corpus.
struct Phase2ProductionProtocolFixtureID: Equatable, Hashable, Sendable {
    let rawValue: String

    fileprivate init(probeID: String) {
        rawValue = "phase2.fixture.\(probeID).v1"
    }
}

struct Phase2ProductionProtocolProbe: Equatable, Sendable {
    let id: String
    let category: Phase2ProductionProtocolProbeCategory
    let expectedOutcome: Phase2ProductionProtocolExpectedOutcome
    let fixtureID: Phase2ProductionProtocolFixtureID
    let acceptanceCriterion: String
}

/// Frozen deterministic fixtures only. F4C owns live execution and qualification observations.
struct Phase2ProductionProtocolProbeCatalog: Equatable, Sendable {
    static let catalogID = "phase2.r1.protocol-probes.v1"
    static let qualificationPolicyAggregateID = "phase2.r1.qualification-policy.v1"

    let probes: [Phase2ProductionProtocolProbe]

    enum TestMutation: Equatable, Sendable {
        case id(index: Int, suffix: String)
        case category(index: Int, value: Phase2ProductionProtocolProbeCategory)
        case expectedOutcome(index: Int, value: Phase2ProductionProtocolExpectedOutcome)
        case fixtureID(index: Int, suffix: String)
        case criterion(index: Int, suffix: String)
        case swap(Int, Int)
    }

    init(
        criterionSuffixForTesting: String = "",
        mutationForTesting: TestMutation? = nil
    ) {
        func probe(
            _ id: String,
            _ category: Phase2ProductionProtocolProbeCategory,
            _ criterion: String
        ) -> Phase2ProductionProtocolProbe {
            .init(
                id: id,
                category: category,
                expectedOutcome: Self.expectedOutcome(for: id),
                fixtureID: .init(probeID: id),
                acceptanceCriterion: criterion + criterionSuffixForTesting
            )
        }
        var values = [
            probe("tool.single.workspace-summary", .toolSelection, "One workspace-summary call yields its exact offered handle."),
            probe("tool.single.selection-explain", .toolSelection, "One selection-explain call yields its exact offered handle."),
            probe("tool.single.function-review", .toolSelection, "One function-review call yields its exact offered handle."),
            probe("tool.multicall.two-ordered", .toolSelection, "Two calls preserve contiguous provider-index order."),
            probe("tool.multicall.three-ordered", .toolSelection, "Three calls preserve contiguous provider-index order."),
            probe("tool.multicall.interleaved", .toolSelection, "Interleaved fragments preserve provider-index order."),
            probe("tool.call-id.non-uuid", .toolSelection, "A bounded non-UUID call ID is preserved byte-for-byte."),
            probe("tool.atomic.id-delayed", .toolSelection, "A complete call ID may first appear in a later chunk."),
            probe("tool.atomic.type-delayed", .toolSelection, "A complete function type may first appear in a later chunk."),
            probe("tool.atomic.name-delayed", .toolSelection, "A complete function name may first appear in a later chunk."),
            probe("tool.atomic.later-omission", .toolSelection, "Frozen atomic metadata may be omitted from later chunks."),
            probe("tool.atomic.id-mutation", .toolSelection, "A changed call ID after first presence rejects."),
            probe("tool.atomic.type-mutation", .toolSelection, "A changed function type after first presence rejects."),
            probe("tool.atomic.name-mutation", .toolSelection, "A changed function name after first presence rejects."),
            probe("tool.arguments.fragmented", .toolSelection, "Argument fragments assemble in arrival order before validation."),
            probe("tool.schema-name-handle-pairing", .toolSelection, "Function, schema, and exact app-issued handle match bijectively."),
            probe("tool.registry-order", .toolSelection, "Projected tools preserve the frozen registry order."),
            probe("tool.argument.missing-required", .toolSelection, "An argument object missing handle_id rejects."),
            probe("tool.argument.unknown", .toolSelection, "An unknown argument property rejects."),
            probe("tool.argument.duplicate", .toolSelection, "A duplicate argument property rejects."),
            probe("tool.argument.wrong-type", .toolSelection, "A non-string handle_id rejects."),
            probe("tool.argument.malformed", .toolSelection, "Malformed argument JSON rejects."),
            probe("tool.argument.trailing", .toolSelection, "Trailing argument JSON bytes reject."),
            probe("tool.proposal.unoffered-name", .toolSelection, "An unoffered function name rejects."),
            probe("tool.proposal.invented-handle", .toolSelection, "An invented handle rejects."),
            probe("tool.proposal.repeated-handle", .toolSelection, "A repeated handle rejects."),
            probe("tool.proposal.duplicate-call-id", .toolSelection, "A duplicate provider call ID rejects."),
            probe("tool.proposal.sparse-index", .toolSelection, "A sparse provider call index rejects."),
            probe("tool.proposal.out-of-range-index", .toolSelection, "A provider call index above two rejects."),
            probe("json.ordinary.recursive-duplicate", .strictJSON, "A duplicate key in nested ordinary SSE JSON rejects."),
            probe("json.usage.recursive-duplicate", .strictJSON, "A duplicate key in nested usage SSE JSON rejects."),
            probe("json.ordinary.trailing", .strictJSON, "Trailing bytes in ordinary SSE JSON reject."),
            probe("json.usage.trailing", .strictJSON, "Trailing bytes in usage SSE JSON reject."),
            probe("json.sse.depth-maximum", .strictJSON, "SSE nesting depth at the inclusive maximum is accepted."),
            probe("json.sse.depth-plus-one", .strictJSON, "SSE nesting depth maximum-plus-one rejects."),
            probe("json.arguments.depth-maximum", .strictJSON, "Argument nesting depth at the inclusive maximum is accepted."),
            probe("json.arguments.depth-plus-one", .strictJSON, "Argument nesting depth maximum-plus-one rejects."),
            probe("json.final.depth-maximum", .strictJSON, "Final nesting depth at the inclusive maximum is accepted."),
            probe("json.final.depth-plus-one", .strictJSON, "Final nesting depth maximum-plus-one rejects."),
            probe("json.sse.tokens-maximum", .strictJSON, "SSE lexical-token count at the inclusive maximum is accepted."),
            probe("json.sse.tokens-plus-one", .strictJSON, "SSE lexical-token maximum-plus-one rejects."),
            probe("json.arguments.tokens-maximum", .strictJSON, "Argument lexical-token count at the inclusive maximum is accepted."),
            probe("json.arguments.tokens-plus-one", .strictJSON, "Argument lexical-token maximum-plus-one rejects."),
            probe("json.final.tokens-maximum", .strictJSON, "Final lexical-token count at the inclusive maximum is accepted."),
            probe("json.final.tokens-plus-one", .strictJSON, "Final lexical-token maximum-plus-one rejects."),
            probe("json.sse.members-maximum", .strictJSON, "SSE aggregate-member count at the inclusive maximum is accepted."),
            probe("json.sse.members-plus-one", .strictJSON, "SSE aggregate-member maximum-plus-one rejects."),
            probe("json.arguments.members-maximum", .strictJSON, "Argument aggregate-member count at the inclusive maximum is accepted."),
            probe("json.arguments.members-plus-one", .strictJSON, "Argument aggregate-member maximum-plus-one rejects."),
            probe("json.final.members-maximum", .strictJSON, "Final aggregate-member count at the inclusive maximum is accepted."),
            probe("json.final.members-plus-one", .strictJSON, "Final aggregate-member maximum-plus-one rejects."),
            probe("tool.output.content", .toolSelection, "Content during tool selection rejects."),
            probe("tool.output.final-answer", .toolSelection, "A final answer during tool selection rejects."),
            probe("tool.finish-reason.wrong", .toolSelection, "A finish reason other than tool_calls rejects."),
            probe("tool.usage.incomplete", .toolSelection, "Incomplete usage rejects."),
            probe("tool.record.after-terminal", .toolSelection, "A record after terminal completion rejects."),
            probe("tool.cancellation.partial", .toolSelection, "Cancellation discards every partial call."),
            probe("request.tool-selection.byte-fixture", .request, "Tool-selection request bytes equal the frozen fixture."),
            probe("request.finalization.byte-fixture", .request, "Finalization request bytes equal the frozen fixture."),
            probe("final.answer", .finalization, "Answer requires nonempty text, exact allowed citations, and empty reason."),
            probe("final.insufficient-evidence", .finalization, "Insufficient evidence requires empty text and citations plus a nonempty reason."),
            probe("final.evidence-id.lowercase", .finalization, "A lowercase evidence UUID rejects."),
            probe("final.evidence-id.mixed-case", .finalization, "A mixed-case evidence UUID rejects."),
            probe("final.evidence-id.braced", .finalization, "A braced evidence UUID rejects."),
            probe("final.evidence-id.hyphenless", .finalization, "A hyphenless evidence UUID rejects."),
            probe("final.evidence-id.padded", .finalization, "A whitespace-padded evidence UUID rejects."),
            probe("final.evidence-id.other-parseable", .finalization, "Any other parseable noncanonical evidence UUID rejects."),
            probe("final.field.unknown", .finalization, "An unknown final-output field rejects."),
            probe("final.field.duplicate", .finalization, "A duplicate final-output field rejects."),
            probe("final.variant.mixed", .finalization, "Mixed answer and insufficient-evidence semantics reject."),
            probe("final.citation.bad", .finalization, "A malformed citation rejects."),
            probe("final.citation.duplicate", .finalization, "A duplicate citation rejects."),
            probe("final.citation.unallowed", .finalization, "An unallowed citation rejects."),
            probe("final.unicode", .finalization, "Valid bounded Unicode text remains exact."),
            probe("final.long-output", .finalization, "Output above the semantic byte ceiling rejects."),
            probe("final.truncation", .finalization, "Truncated final JSON rejects."),
            probe("final.prompt-injection-as-data", .finalization, "Adversarial project text remains canonical user data."),
            probe("final.tool-call", .finalization, "A tool call during finalization rejects."),
            probe("identity.prompt-byte-drift", .identity, "A prompt-module byte change alters its module identity."),
            probe("identity.registry-description-drift", .identity, "A function-description change alters the registry aggregate."),
            probe("identity.registry-order-drift", .identity, "A registry-order change alters the registry aggregate."),
            probe("identity.schema-semantic-drift", .identity, "A schema keyword or value change alters its owning aggregate."),
            probe("identity.schema-set-version-drift", .identity, "A schema-set version change alters the registry aggregate."),
            probe("identity.protocol-version-drift", .identity, "A wire, inference, or OpenAI protocol version change alters inference transport."),
            probe("identity.probe-catalog-drift", .identity, "A probe ID, category, order, or criterion change alters qualification policy."),
            probe("limit.preview-delta-maximum", .limits, "Preview-delta bytes at the inclusive maximum are accepted."),
            probe("limit.preview-delta-plus-one", .limits, "Preview-delta bytes maximum-plus-one rejects."),
            probe("limit.preview-cumulative-maximum", .limits, "Cumulative preview bytes at the inclusive maximum are accepted."),
            probe("limit.preview-cumulative-plus-one", .limits, "Cumulative preview bytes maximum-plus-one rejects."),
            probe("limit.answer-text-maximum", .limits, "Answer text bytes at the inclusive maximum are accepted."),
            probe("limit.answer-text-plus-one", .limits, "Answer text bytes maximum-plus-one rejects."),
            probe("limit.reason-maximum", .limits, "Abstention reason bytes at the inclusive maximum are accepted."),
            probe("limit.reason-plus-one", .limits, "Abstention reason bytes maximum-plus-one rejects."),
            probe("limit.final-envelope-maximum", .limits, "Raw final-envelope bytes at the inclusive maximum are accepted."),
            probe("limit.final-envelope-plus-one", .limits, "Raw final-envelope bytes maximum-plus-one rejects."),
            probe("limit.event-maximum", .limits, "Per-event bytes at the inclusive maximum are accepted."),
            probe("limit.event-plus-one", .limits, "Per-event bytes maximum-plus-one rejects."),
            probe("limit.cumulative-event-maximum", .limits, "Cumulative event bytes at the inclusive maximum are accepted."),
            probe("limit.cumulative-event-plus-one", .limits, "Cumulative event bytes maximum-plus-one rejects."),
        ]
        if let mutationForTesting {
            switch mutationForTesting {
            case let .id(index, suffix):
                guard values.indices.contains(index) else { break }
                let value = values[index]
                values[index] = .init(
                    id: value.id + suffix,
                    category: value.category,
                    expectedOutcome: value.expectedOutcome,
                    fixtureID: value.fixtureID,
                    acceptanceCriterion: value.acceptanceCriterion
                )
            case let .category(index, category):
                guard values.indices.contains(index) else { break }
                let value = values[index]
                values[index] = .init(
                    id: value.id,
                    category: category,
                    expectedOutcome: value.expectedOutcome,
                    fixtureID: value.fixtureID,
                    acceptanceCriterion: value.acceptanceCriterion
                )
            case let .expectedOutcome(index, expectedOutcome):
                guard values.indices.contains(index) else { break }
                let value = values[index]
                values[index] = .init(
                    id: value.id,
                    category: value.category,
                    expectedOutcome: expectedOutcome,
                    fixtureID: value.fixtureID,
                    acceptanceCriterion: value.acceptanceCriterion
                )
            case let .fixtureID(index, suffix):
                guard values.indices.contains(index) else { break }
                let value = values[index]
                values[index] = .init(
                    id: value.id,
                    category: value.category,
                    expectedOutcome: value.expectedOutcome,
                    fixtureID: .init(probeID: value.id + suffix),
                    acceptanceCriterion: value.acceptanceCriterion
                )
            case let .criterion(index, suffix):
                guard values.indices.contains(index) else { break }
                let value = values[index]
                values[index] = .init(
                    id: value.id,
                    category: value.category,
                    expectedOutcome: value.expectedOutcome,
                    fixtureID: value.fixtureID,
                    acceptanceCriterion: value.acceptanceCriterion + suffix
                )
            case let .swap(first, second):
                guard values.indices.contains(first), values.indices.contains(second) else { break }
                values.swapAt(first, second)
            }
        }
        probes = values
    }

    private var canonicalValue: Phase2ProductionProbeCanonicalValue {
        .object([
            "catalog_id": .string(Self.catalogID),
            "probes": .array(probes.map { probe in
                .object([
                    "acceptance_criterion": .string(probe.acceptanceCriterion),
                    "category": .string(probe.category.rawValue),
                    "expected_outcome": .string(probe.expectedOutcome.rawValue),
                    "fixture_id": .string(probe.fixtureID.rawValue),
                    "id": .string(probe.id),
                ])
            }),
            "version": .number("1"),
        ])
    }

    var qualificationPolicyIdentity: Phase2ProductionArtifactIdentity {
        let digestBytes = SHA256.hash(data: canonicalValue.lengthFramedBytes())
        let hex = Array("0123456789abcdef".utf8)
        let digest = String(decoding: digestBytes.flatMap { byte in
            [hex[Int(byte >> 4)], hex[Int(byte & 0x0F)]]
        }, as: UTF8.self)
        return .init(
            id: Self.qualificationPolicyAggregateID,
            version: 1,
            sha256: digest
        )
    }

    private static func expectedOutcome(
        for probeID: String
    ) -> Phase2ProductionProtocolExpectedOutcome {
        if probeID.hasPrefix("identity.") {
            return .identityChanged
        }
        if probeID.hasPrefix("request.") {
            return .exactBytesMatched
        }
        if probeID == "tool.cancellation.partial" {
            return .cancelledWithoutSemanticOutput
        }
        let accepted: Set<String> = [
            "tool.single.workspace-summary",
            "tool.single.selection-explain",
            "tool.single.function-review",
            "tool.multicall.two-ordered",
            "tool.multicall.three-ordered",
            "tool.multicall.interleaved",
            "tool.call-id.non-uuid",
            "tool.atomic.id-delayed",
            "tool.atomic.type-delayed",
            "tool.atomic.name-delayed",
            "tool.atomic.later-omission",
            "tool.arguments.fragmented",
            "tool.schema-name-handle-pairing",
            "tool.registry-order",
            "final.answer",
            "final.insufficient-evidence",
            "final.unicode",
            "final.prompt-injection-as-data",
            "json.sse.depth-maximum",
            "json.arguments.depth-maximum",
            "json.final.depth-maximum",
            "json.sse.tokens-maximum",
            "json.arguments.tokens-maximum",
            "json.final.tokens-maximum",
            "json.sse.members-maximum",
            "json.arguments.members-maximum",
            "json.final.members-maximum",
            "limit.preview-delta-maximum",
            "limit.preview-cumulative-maximum",
            "limit.answer-text-maximum",
            "limit.reason-maximum",
            "limit.final-envelope-maximum",
            "limit.event-maximum",
            "limit.cumulative-event-maximum",
        ]
        return accepted.contains(probeID) ? .accepted : .rejected
    }
}

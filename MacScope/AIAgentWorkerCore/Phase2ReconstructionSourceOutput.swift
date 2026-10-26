import Foundation
#if TESTING_WORKER_PRINCIPAL
@testable import MacScope
#endif

/// One bounded source response, separate from planning and final-synthesis accumulators.
enum Phase2ReconstructionSourceOutput {
    static let schemaBlueprint: Phase2ProductionJSONValue = .object([
        "profile": .string(ReconstructionSourceInferenceContract.profileID),
        "version": .integer(1), "path": .string("candidate.c"),
        "maximum_source_utf8_bytes": .integer(65_536), "maximum_references": .integer(64),
        "fields": .array(["profileID", "parentRevisionSHA256", "sourceText", "evidenceIDs"].map { .string($0) }),
        "additional_properties": .bool(false), "parent_nil_encoding": .string("none")
    ])
    static func schema(for request: ReconstructionSourceRevisionRequest) throws -> Phase2ProductionJSONSchema {
        try request.validate()
        return try .object(properties: [
            .init(name: "profileID", schema: .string(enumeration: [request.profileID])),
            .init(name: "parentRevisionSHA256", schema: .string(enumeration: [request.parentRevisionSHA256 ?? "none"])),
            .init(name: "sourceText", schema: .string(minLength: 1, maxLength: 65_536)),
            .init(name: "evidenceIDs", schema: .array(items: .string(enumeration: request.context.evidenceIDs.map(\.uuidString)), minItems: 1, maxItems: 64, uniqueItems: true))
        ], required: ["profileID", "parentRevisionSHA256", "sourceText", "evidenceIDs"])
    }
}

struct Phase2ReconstructionSourceAccumulator: Sendable {
    private var bytes = Data()
    private var usage: Phase2AIWorkerWireUsage?
    private var done = false
    private var retired = false
    mutating func consume(_ event: Phase2ReconstructionChatStreamEvent) throws {
        guard !done, !retired else { throw Phase2ReconstructionRoundAccumulatorError.invalidSequence }
        switch event {
        case .contentDelta(let text):
            guard usage == nil else { retired = true; throw Phase2ReconstructionRoundAccumulatorError.invalidSequence }
            guard bytes.count + text.utf8.count <= 524_288 else { retired = true; throw Phase2ReconstructionRoundAccumulatorError.outputTooLarge }
            bytes.append(contentsOf: text.utf8)
        case .usage(let value):
            let (total, overflow) = value.promptTokens.addingReportingOverflow(value.completionTokens)
            guard usage == nil, !overflow, value.promptTokens >= 0, value.completionTokens >= 0,
                  value.completionTokens <= 16_384, total == value.totalTokens else { retired = true; throw Phase2ReconstructionRoundAccumulatorError.invalidSequence }
            usage = value
        case .done:
            guard usage != nil, !bytes.isEmpty else { retired = true; throw Phase2ReconstructionRoundAccumulatorError.invalidSequence }
            done = true
        }
    }
    func finish(for request: ReconstructionSourceRevisionRequest) throws -> (ReconstructionSourceRevisionCandidate, Phase2AIWorkerWireUsage) {
        guard done, let usage else { throw Phase2ReconstructionRoundAccumulatorError.invalidSequence }
        do {
            let parsed = try Phase2StrictJSONParser().parse(bytes, limits: .init(maximumBytes: 524_288,
                maximumDepth: 8, maximumTokens: 512, maximumMembersAndElements: 256))
            guard let object = parsed.objectValue,
                  Set(object.keys) == ["profileID", "parentRevisionSHA256", "sourceText", "evidenceIDs"] else { throw Phase2ReconstructionRoundAccumulatorError.malformedOutput }
            let output = try JSONDecoder().decode(Output.self, from: bytes)
            let candidate = ReconstructionSourceRevisionCandidate(profileID: output.profileID,
                parentRevisionSHA256: output.parentRevisionSHA256 == "none" ? nil : output.parentRevisionSHA256,
                sourceText: output.sourceText, evidenceIDs: output.evidenceIDs)
            try candidate.validate(for: request)
            return (candidate, usage)
        } catch { throw Phase2ReconstructionRoundAccumulatorError.malformedOutput }
    }
    private struct Output: Decodable {
        let profileID: String
        let parentRevisionSHA256: String
        let sourceText: String
        let evidenceIDs: [UUID]
    }
}

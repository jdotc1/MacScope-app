import Foundation
#if TESTING_WORKER_PRINCIPAL
@testable import MacScope
#endif

enum Phase2ReconstructionChatStreamEvent: Equatable, Sendable {
    case contentDelta(String)
    case usage(Phase2AIWorkerWireUsage)
    case done
}

enum Phase2ReconstructionRoundAccumulatorError: Error, Equatable, Sendable {
    case invalidSequence
    case outputTooLarge
    case malformedOutput
}

struct Phase2ReconstructionRoundAccumulator: Sendable {
    private static let maximumOutputBytes = 65_536
    private static let maximumCompletionTokens = 16_384
    private static let outputJSONLimits = Phase2StrictJSONLimits(
        maximumBytes: maximumOutputBytes,
        maximumDepth: 8,
        maximumTokens: 4_096,
        maximumMembersAndElements: 4_096
    )
    private static let roundUnescapedAuthorityKeys: Set<String> = [
        "job_id", "round_id", "selected_handle_ids", "disposition", "subject", "category",
        "gap_id", "handle_id", "evidence_id",
    ]
    private static let finalUnescapedAuthorityKeys: Set<String> = ["kind", "evidence_ids"]

    private var content = Data()
    private var usage: Phase2AIWorkerWireUsage?
    private var isDone = false
    private var isRetired = false

    mutating func consume(_ event: Phase2ReconstructionChatStreamEvent) throws {
        guard !isDone, !isRetired else {
            throw Phase2ReconstructionRoundAccumulatorError.invalidSequence
        }
        switch event {
        case .contentDelta(let delta):
            guard usage == nil else {
                isRetired = true
                throw Phase2ReconstructionRoundAccumulatorError.invalidSequence
            }
            let (nextByteCount, byteCountOverflow) = content.count.addingReportingOverflow(
                delta.utf8.count
            )
            guard !byteCountOverflow, nextByteCount <= Self.maximumOutputBytes else {
                isRetired = true
                throw Phase2ReconstructionRoundAccumulatorError.outputTooLarge
            }
            content.append(contentsOf: delta.utf8)
        case .usage(let value):
            let (expectedTotalTokens, tokenCountOverflow) = value.promptTokens
                .addingReportingOverflow(value.completionTokens)
            guard usage == nil,
                  value.promptTokens >= 0,
                  value.completionTokens >= 0,
                  value.completionTokens <= Self.maximumCompletionTokens,
                  !tokenCountOverflow,
                  value.totalTokens == expectedTotalTokens
            else {
                isRetired = true
                throw Phase2ReconstructionRoundAccumulatorError.invalidSequence
            }
            usage = value
        case .done:
            guard !content.isEmpty, usage != nil else {
                isRetired = true
                throw Phase2ReconstructionRoundAccumulatorError.invalidSequence
            }
            isDone = true
        }
    }

    func finishRound() throws -> (ReconstructionInferenceRoundCandidate, Phase2AIWorkerWireUsage) {
        guard isDone, let usage else {
            throw Phase2ReconstructionRoundAccumulatorError.invalidSequence
        }
        do {
            try validateRoundShape(content)
            let value = try decoder.decode(RoundOutput.self, from: content)
            return (.init(
                jobID: value.jobID,
                checkpointRevision: value.checkpointRevision,
                roundID: value.roundID,
                selectedHandleIDs: value.selectedHandleIDs,
                disposition: value.disposition,
                unresolvedGaps: value.unresolvedGaps,
                resolvedGaps: value.resolvedGaps
            ), usage)
        } catch {
            throw Phase2ReconstructionRoundAccumulatorError.malformedOutput
        }
    }

    func finishFinal() throws -> (ReconstructionFinalSynthesisCandidate, Phase2AIWorkerWireUsage) {
        guard isDone, let usage else {
            throw Phase2ReconstructionRoundAccumulatorError.invalidSequence
        }
        do {
            try validateFinalShape(content)
            let value = try decoder.decode(FinalOutput.self, from: content)
            return (.init(kind: value.kind, text: value.text, evidenceIDs: value.evidenceIDs), usage)
        } catch {
            throw Phase2ReconstructionRoundAccumulatorError.malformedOutput
        }
    }

    private var decoder: JSONDecoder { JSONDecoder() }

    private func validateRoundShape(_ data: Data) throws {
        let parsed = try Phase2StrictJSONParser().parse(
            data,
            limits: Self.outputJSONLimits,
            requiringUnescapedStringValuesForObjectKeys: Self.roundUnescapedAuthorityKeys
        )
        guard let object = parsed.objectValue,
              Set(object.keys) == [
                  "job_id", "checkpoint_revision", "round_id", "selected_handle_ids",
                  "disposition", "unresolved_gaps", "resolved_gaps",
              ],
              isCanonicalUUID(object["job_id"]),
              isCanonicalUUID(object["round_id"]),
              let selectedHandleIDs = object["selected_handle_ids"]?.arrayValue,
              selectedHandleIDs.allSatisfy(isCanonicalUUID),
              let gaps = object["unresolved_gaps"]?.arrayValue,
              gaps.allSatisfy({ value in
                  guard let gap = value.objectValue else { return false }
                  return Set(gap.keys) == ["subject", "category", "reason"]
              }),
              let resolvedGaps = object["resolved_gaps"]?.arrayValue,
              resolvedGaps.allSatisfy({
                  guard let gap = $0.objectValue,
                        Set(gap.keys) == ["gap_id", "handle_id", "evidence_id"] else {
                      return false
                  }
                  return isCanonicalUUID(gap["gap_id"])
                      && isCanonicalUUID(gap["handle_id"])
                      && isCanonicalUUID(gap["evidence_id"])
              })
        else { throw Phase2ReconstructionRoundAccumulatorError.malformedOutput }
    }

    private func validateFinalShape(_ data: Data) throws {
        let parsed = try Phase2StrictJSONParser().parse(
            data,
            limits: Self.outputJSONLimits,
            requiringUnescapedStringValuesForObjectKeys: Self.finalUnescapedAuthorityKeys
        )
        guard let object = parsed.objectValue,
              Set(object.keys) == ["kind", "text", "evidence_ids"],
              let evidenceIDs = object["evidence_ids"]?.arrayValue,
              evidenceIDs.allSatisfy(isCanonicalUUID)
        else { throw Phase2ReconstructionRoundAccumulatorError.malformedOutput }
    }

    private func isCanonicalUUID(_ value: Phase2ProductionJSONValue) -> Bool {
        guard let string = value.stringValue else { return false }
        return UUID(uuidString: string)?.uuidString == string
    }

    private func isCanonicalUUID(_ value: Phase2ProductionJSONValue?) -> Bool {
        value.map(isCanonicalUUID) ?? false
    }
}

private struct RoundOutput: Decodable {
    let jobID: UUID
    let checkpointRevision: UInt64
    let roundID: UUID
    let selectedHandleIDs: [UUID]
    let disposition: ReconstructionInferenceDisposition
    let unresolvedGaps: [ReconstructionEvidenceGapDeclaration]
    let resolvedGaps: [ReconstructionEvidenceGapResolutionClaim]

    enum CodingKeys: String, CodingKey {
        case jobID = "job_id"
        case checkpointRevision = "checkpoint_revision"
        case roundID = "round_id"
        case selectedHandleIDs = "selected_handle_ids"
        case disposition
        case unresolvedGaps = "unresolved_gaps"
        case resolvedGaps = "resolved_gaps"
    }
}

private struct FinalOutput: Decodable {
    let kind: ReconstructionFinalSynthesisKind
    let text: String
    let evidenceIDs: [UUID]

    enum CodingKeys: String, CodingKey {
        case kind, text
        case evidenceIDs = "evidence_ids"
    }
}

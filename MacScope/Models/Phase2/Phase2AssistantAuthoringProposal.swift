import Foundation

enum Phase2AssistantAuthoringOperation: String, Codable, CaseIterable, Sendable {
    case rename
    case comment
    case type
    case byteEdit = "byte_edit"

    var title: String {
        switch self {
        case .rename: "Rename"
        case .comment: "Edit Comment"
        case .type: "Apply Type"
        case .byteEdit: "Patch Bytes"
        }
    }
}

struct Phase2AssistantAuthoringProposalDraft: Equatable, Sendable {
    static let openingTag = "<macscope-authoring-proposal-v1>"
    static let closingTag = "</macscope-authoring-proposal-v1>"
    static let maximumEnvelopeBytes = 4_096

    let operation: Phase2AssistantAuthoringOperation
    let value: String
    let evidenceID: UUID

    /// Extracts one terminal, inert proposal envelope. Unknown keys, non-terminal content, and
    /// over-budget payloads fail closed; the answer remains usable without authoring authority.
    static func extract(from text: String) -> (answer: String, draft: Self?) {
        guard let opening = text.range(of: openingTag, options: .backwards),
              let closing = text.range(
                of: closingTag,
                options: [],
                range: opening.upperBound..<text.endIndex
              ),
              text[closing.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return (text, nil) }

        let payload = String(text[opening.upperBound..<closing.lowerBound])
        guard payload.utf8.count <= maximumEnvelopeBytes,
              let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["operation", "value", "evidence_id"],
              let operationText = object["operation"] as? String,
              let operation = Phase2AssistantAuthoringOperation(rawValue: operationText),
              let rawValue = object["value"] as? String,
              let evidenceText = object["evidence_id"] as? String,
              let evidenceID = UUID(uuidString: evidenceText),
              let value = validatedValue(rawValue, for: operation)
        else { return (text, nil) }

        let answer = text[..<opening.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty else { return (text, nil) }
        return (answer, Self(operation: operation, value: value, evidenceID: evidenceID))
    }

    private static func validatedValue(
        _ rawValue: String,
        for operation: Phase2AssistantAuthoringOperation
    ) -> String? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        switch operation {
        case .rename, .type:
            guard value.utf8.count <= 256,
                  !value.contains(where: \.isNewline)
            else { return nil }
        case .comment:
            guard value.utf8.count <= 2_048 else { return nil }
        case .byteEdit:
            guard value.utf8.count <= 8_192,
                  BytePatch.parse(hex: value) != nil
            else { return nil }
        }
        return value
    }
}

struct Phase2AssistantAuthoringProposal: Equatable, Sendable {
    let id: UUID
    let intent: Phase2AssistantIntent
    let operation: Phase2AssistantAuthoringOperation
    let value: String
    let evidenceID: UUID
    let citations: [Phase2ReadCitation]
    let precondition: Phase2ReadPrecondition
    let image: Phase2ReadImageIdentity
    let openingSelection: ImageAddress
    let target: ImageAddress
    let instructionEndExclusive: UInt64
    let originalValue: String?

    var imageAddressLabel: String {
        "image \(image.slot.rawValue) · 0x\(String(target.address, radix: 16))"
    }

    var instructionSpanLabel: String {
        "0x\(String(target.address, radix: 16))–0x\(String(instructionEndExclusive, radix: 16))"
    }

    var originalDisplayValue: String { originalValue ?? "(none)" }

    var citationDisplays: [Phase2AssistantCitationDisplay] {
        citations.map { citation in
            Phase2AssistantCitationDisplay(
                id: citation.id,
                title: "Evidence \(evidenceID.uuidString)",
                detail: citation.target.displayLabel,
                target: citation.target
            )
        }
    }
}

enum Phase2AssistantAuthoringProposalReviewState: Equatable, Sendable {
    case inactive
    case staged(Phase2AssistantAuthoringProposal)
    case applied(Phase2AssistantAuthoringProposal)
    case rejected(Phase2AssistantAuthoringProposal)
    case refused(Phase2AssistantAuthoringProposal, reason: String)

    var proposal: Phase2AssistantAuthoringProposal? {
        switch self {
        case .inactive: nil
        case .staged(let proposal), .applied(let proposal), .rejected(let proposal),
             .refused(let proposal, _): proposal
        }
    }

    var isActive: Bool { proposal != nil }
    var canDecide: Bool {
        if case .staged = self { true } else { false }
    }

    var status: String {
        switch self {
        case .inactive: "Inactive"
        case .staged: "Awaiting review"
        case .applied: "Accepted and applied"
        case .rejected: "Rejected"
        case .refused(_, let reason): "Refused: \(reason)"
        }
    }
}

extension Phase2AssistantIntent {
    /// The concrete proposal envelope offered to the model by default, anchored
    /// to the evidence and selected address that staging will accept.
    func authoringProposalInstruction(evidenceID: UUID, address: UInt64) -> String? {
        let operations: String
        let allowed: [Phase2AssistantAuthoringOperation]
        switch self {
        case .explainSelection:
            operations = "Propose a concise comment that says what this instruction does."
            allowed = [.comment]
        case .reviewFunction:
            operations = """
            Normally propose a concise comment for this instruction. When the cited evidence supports it, \
            use "rename" with a new function name or "type" with a type name instead.
            """
            allowed = [.comment, .rename, .type]
        case .askMacScope:
            return nil
        }
        let evidence = evidenceID.uuidString
        // The worker reads the "Allowed operations:" and "Proposal evidence:" lines to add a
        // required `proposal` field to the final-answer schema; the envelope stays as the text
        // fallback for a final object without that field.
        return """
        Give exactly one MacScope proposal for the selected instruction at \
        0x\(String(address, radix: 16)). \(operations)
        Allowed operations: \(allowed.map(\.rawValue).joined(separator: ", "))
        Proposal evidence: \(evidence)
        Put it in the final object's proposal field, which is required: {"operation":"comment","value":"<concise comment>","evidence_id":"\(evidence)"}
        Only if the final object has no proposal field, end the answer text with this envelope instead:
        <macscope-authoring-proposal-v1>{"operation":"comment","value":"<concise comment>","evidence_id":"\(evidence)"}</macscope-authoring-proposal-v1>
        Keep evidence_id "\(evidence)" and include it in the answer's evidence IDs. Keep the envelope on one line \
        as valid JSON, and never write it into the answer text when you fill the proposal field. \
        MacScope applies it only after the user accepts it. Do not propose shell or debugger commands.
        """
    }
}

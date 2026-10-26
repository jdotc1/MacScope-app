import Foundation

enum Phase2GroundedFinalDecodingError: Error, Equatable, Sendable {
    case malformedEnvelope
    case envelopeByteLimitExceeded
    case resourceLimitExceeded
    case invalidSchema
    case invalidText
    case textByteLimitExceeded
    case invalidReason
    case reasonByteLimitExceeded
    case evidenceLimitExceeded
    case invalidEvidenceID
    case duplicateEvidenceID
    case unknownEvidenceID
}

enum Phase2GroundedFinalOutput: Equatable, Sendable {
    case answer(text: String, evidenceIDs: [UUID])
    case insufficientEvidence(text: String)
}

struct Phase2GroundedFinalDecoder: Sendable {
    static let maximumTextBytes = 60_000
    static let maximumReasonBytes = 4_096
    static let maximumEnvelopeBytes = 65_536
    static let maximumEvidenceReferences = 3

    /// `proposalOperations` is nonempty only when the request offered an authoring proposal
    /// (see `Phase2GroundedFinalProposal`); the object may then carry a `proposal` field.
    func decode(
        _ data: Data,
        allowedEvidenceIDs: Set<UUID>,
        proposalOperations: [String] = []
    ) throws -> Phase2GroundedFinalOutput {
        guard data.count <= Self.maximumEnvelopeBytes else {
            throw Phase2GroundedFinalDecodingError.envelopeByteLimitExceeded
        }

        let root: Phase2FinalJSONValue
        do {
            var parser = Phase2FinalJSONParser(data: data)
            root = try parser.parse()
        } catch Phase2FinalJSONParser.Failure.duplicateKey {
            throw Phase2GroundedFinalDecodingError.invalidSchema
        } catch Phase2FinalJSONParser.Failure.resourceLimit {
            throw Phase2GroundedFinalDecodingError.resourceLimitExceeded
        } catch {
            throw Phase2GroundedFinalDecodingError.malformedEnvelope
        }

        let baseKeys: Set<String> = ["kind", "text", "evidence_ids", "reason"]
        guard case .object(let object) = root,
              Set(object.keys) == baseKeys
                || (!proposalOperations.isEmpty && Set(object.keys) == baseKeys.union(["proposal"])),
              case .string(let kindValue)? = object["kind"],
              case .string(let textValue)? = object["text"],
              case .array(let encodedEvidence)? = object["evidence_ids"],
              case .string(let reasonValue)? = object["reason"]
        else {
            throw Phase2GroundedFinalDecodingError.invalidSchema
        }
        let kind = kindValue.value
        let text = textValue.value
        let reason = reasonValue.value

        switch kind {
        case "answer":
            guard reason.isEmpty else {
                throw Phase2GroundedFinalDecodingError.invalidSchema
            }
            try validateAnswerText(text)
            let evidenceIDs = try validateEvidence(encodedEvidence, allowedEvidenceIDs: allowedEvidenceIDs)
            guard let proposal = object["proposal"], proposal != .null else {
                return .answer(text: Self.trimmingTrailingJSONRemnants(from: text), evidenceIDs: evidenceIDs)
            }
            // A structured proposal is the only one: drop any envelope the model also wrote
            // into the prose, so the answer shows none and the app stages at most one.
            let prose = Self.trimmingTrailingJSONRemnants(
                from: Phase2GroundedFinalProposal.removingEnvelopes(from: text)
            )
            guard !prose.isEmpty else { return .answer(text: text, evidenceIDs: evidenceIDs) }
            // Map a valid proposal into the app's existing envelope so it passes the same
            // extraction, evidence, target and review checks as a text envelope. One that is
            // invalid or does not fit is dropped and the answer stands without it.
            guard let envelope = Phase2GroundedFinalProposal.envelope(
                    from: proposal,
                    operations: proposalOperations,
                    allowedEvidenceIDs: allowedEvidenceIDs
                  ),
                  (prose + "\n\n" + envelope).utf8.count <= Self.maximumTextBytes
            else { return .answer(text: prose, evidenceIDs: evidenceIDs) }
            return .answer(text: prose + "\n\n" + envelope, evidenceIDs: evidenceIDs)

        case "insufficient_evidence":
            guard text.isEmpty, encodedEvidence.isEmpty else {
                throw Phase2GroundedFinalDecodingError.invalidSchema
            }
            try validateReason(reason)
            return .insufficientEvidence(text: reason)

        default:
            throw Phase2GroundedFinalDecodingError.invalidSchema
        }
    }

    /// The answer text without stray JSON punctuation the model left at the end of its prose,
    /// such as an unmatched closing brace or quote or the start of an unfinished object
    /// (`}`, `"}`, `{\`). A terminal proposal envelope is kept, and the prose before it is
    /// trimmed the same way. Text with no remnant, or only remnants, is returned unchanged.
    static func trimmingTrailingJSONRemnants(from text: String) -> String {
        var prose = Substring(text)
        var envelope: Substring = ""
        if let opening = text.range(of: Phase2GroundedFinalProposal.openingTag, options: .backwards),
           let closing = text.range(
            of: Phase2GroundedFinalProposal.closingTag,
            range: opening.upperBound..<text.endIndex
           ),
           text[closing.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            prose = text[..<opening.lowerBound]
            envelope = text[opening.lowerBound..<closing.upperBound]
        }
        var trimmed = prose.trimmingCharacters(in: .whitespacesAndNewlines)
        var removed = false
        while let last = trimmed.last {
            let dangling: Bool
            switch last {
            case "{", "\\":
                dangling = true
            case "}":
                dangling = trimmed.filter { $0 == "}" }.count > trimmed.filter { $0 == "{" }.count
            case "\"":
                dangling = trimmed.filter { $0 == "\"" }.count % 2 == 1
            default:
                dangling = false
            }
            guard dangling else { break }
            trimmed.removeLast()
            trimmed = trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
            removed = true
        }
        guard removed, !trimmed.isEmpty else { return text }
        return envelope.isEmpty ? trimmed : trimmed + "\n\n" + envelope
    }

    private func validateAnswerText(_ text: String) throws {
        guard !text.isEmpty else {
            throw Phase2GroundedFinalDecodingError.invalidText
        }
        guard text.utf8.count <= Self.maximumTextBytes else {
            throw Phase2GroundedFinalDecodingError.textByteLimitExceeded
        }
    }

    private func validateReason(_ reason: String) throws {
        guard !reason.isEmpty else {
            throw Phase2GroundedFinalDecodingError.invalidReason
        }
        guard reason.utf8.count <= Self.maximumReasonBytes else {
            throw Phase2GroundedFinalDecodingError.reasonByteLimitExceeded
        }
    }

    private func validateEvidence(
        _ values: [Phase2FinalJSONValue],
        allowedEvidenceIDs: Set<UUID>
    ) throws -> [UUID] {
        guard !values.isEmpty else {
            throw Phase2GroundedFinalDecodingError.invalidSchema
        }
        guard values.count <= Self.maximumEvidenceReferences else {
            throw Phase2GroundedFinalDecodingError.evidenceLimitExceeded
        }

        var result: [UUID] = []
        var seen: Set<UUID> = []
        for value in values {
            guard case .string(let encodedValue) = value,
                  !encodedValue.sourceContainsEscape
            else {
                throw Phase2GroundedFinalDecodingError.invalidEvidenceID
            }
            let encoded = encodedValue.value
            guard
                  encoded.utf8.count == 36,
                  let evidenceID = UUID(uuidString: encoded),
                  evidenceID.uuidString == encoded
            else {
                throw Phase2GroundedFinalDecodingError.invalidEvidenceID
            }
            guard seen.insert(evidenceID).inserted else {
                throw Phase2GroundedFinalDecodingError.duplicateEvidenceID
            }
            guard allowedEvidenceIDs.contains(evidenceID) else {
                throw Phase2GroundedFinalDecodingError.unknownEvidenceID
            }
            result.append(evidenceID)
        }
        return result
    }
}

/// The inert authoring proposal a grounded final object may carry in its `proposal` field.
///
/// The app offers one only to Explain Selection and Review Function finalization, through the
/// `proposal_protocol` section, which names the operations it allows on one line. The worker
/// turns a valid proposal object into the app's text envelope; the app alone decides whether
/// to stage it.
enum Phase2GroundedFinalProposal {
    static let openingTag = "<macscope-authoring-proposal-v1>"
    static let closingTag = "</macscope-authoring-proposal-v1>"
    static let operationsLinePrefix = "Allowed operations: "
    /// Operations a proposal section may offer, in schema order. Byte edits are never offered.
    static let offerableOperations = ["comment", "rename", "type"]
    static let maximumValueBytes = 2_048

    /// The operations the section allows, or none when it does not name them exactly once.
    static func operations(inSection section: String) -> [String] {
        let lines = section.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { $0.hasPrefix(operationsLinePrefix) }
        guard lines.count == 1 else { return [] }
        var list = lines[0].dropFirst(operationsLinePrefix.count)
        if list.hasSuffix(".") { list = list.dropLast() }
        let names = list.components(separatedBy: ", ")
        guard !names.isEmpty, Set(names).count == names.count,
              names.allSatisfy(offerableOperations.contains)
        else { return [] }
        return offerableOperations.filter(names.contains)
    }

    /// Proposal operations for a finalization goal, read from its app-authored section.
    static func operations(inUserGoal goal: String) -> [String] {
        Phase2GroundedPromptCatalog.authoringProposalSection(in: goal)
            .map { operations(inSection: $0.section) } ?? []
    }

    /// Proposal operations for a compiled finalization user prompt, read from its
    /// `proposal_protocol` key.
    static func operations(inUserPrompt prompt: String) -> [String] {
        offer(inUserPrompt: prompt).operations
    }

    /// What a proposal section offers: its allowed operations and whether it names the app's
    /// proposal anchor, which makes the proposal a required object rather than nullable.
    struct Offer: Equatable, Sendable {
        static let none = Offer(operations: [], anchored: false)
        let operations: [String]
        let anchored: Bool
    }

    static let anchorLinePrefix = "Proposal evidence: "

    /// The section's offer; it is anchored only when it allows operations and names exactly
    /// one canonical anchor evidence ID.
    static func offer(inSection section: String) -> Offer {
        let operations = operations(inSection: section)
        let anchors = section.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { $0.hasPrefix(anchorLinePrefix) }
            .map { String($0.dropFirst(anchorLinePrefix.count)) }
        let anchored = !operations.isEmpty && anchors.count == 1
            && UUID(uuidString: anchors[0])?.uuidString == anchors[0]
        return Offer(operations: operations, anchored: anchored)
    }

    /// The offer of a compiled finalization user prompt, read from its `proposal_protocol` key.
    static func offer(inUserPrompt prompt: String) -> Offer {
        guard prompt.contains("\"proposal_protocol\""),
              let object = try? JSONSerialization.jsonObject(with: Data(prompt.utf8)) as? [String: Any],
              let section = object["proposal_protocol"] as? String
        else { return .none }
        return offer(inSection: section)
    }

    /// The envelope for a valid, non-null proposal value, or nil.
    static func envelope(
        from value: Phase2FinalJSONValue,
        operations: [String],
        allowedEvidenceIDs: Set<UUID>
    ) -> String? {
        guard !operations.isEmpty,
              case .object(let fields) = value,
              Set(fields.keys) == ["operation", "value", "evidence_id"],
              case .string(let operation)? = fields["operation"],
              operations.contains(operation.value),
              case .string(let proposed)? = fields["value"],
              !proposed.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              proposed.value.utf8.count <= maximumValueBytes,
              case .string(let encodedEvidence)? = fields["evidence_id"],
              !encodedEvidence.sourceContainsEscape,
              encodedEvidence.value.utf8.count == 36,
              let evidenceID = UUID(uuidString: encodedEvidence.value),
              evidenceID.uuidString == encodedEvidence.value,
              allowedEvidenceIDs.contains(evidenceID)
        else { return nil }
        let payload = Phase2ProductionJSONValue.object([
            "evidence_id": .string(encodedEvidence.value),
            "operation": .string(operation.value),
            "value": .string(proposed.value),
        ]).canonicalJSONBytes()
        return openingTag + String(decoding: payload, as: UTF8.self) + closingTag
    }

    /// The answer prose without any envelope the model may also have written, wherever it
    /// appears. An opening tag with no closing tag after it is left as prose.
    static func removingEnvelopes(from text: String) -> String {
        var prose = text
        while let opening = prose.range(of: openingTag),
              let closing = prose.range(of: closingTag, range: opening.upperBound..<prose.endIndex) {
            prose.removeSubrange(opening.lowerBound..<closing.upperBound)
        }
        return prose.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// A narrow, owned JSON parser for the untrusted final provider value. It emits only
/// categorical failures and retains no provider text outside the duration of decoding.
indirect enum Phase2FinalJSONValue: Equatable, Sendable {
    case object([String: Phase2FinalJSONValue])
    case array([Phase2FinalJSONValue])
    case string(Phase2FinalJSONString)
    case number
    case boolean
    case null
}

struct Phase2FinalJSONString: Equatable, Sendable {
    let value: String
    let sourceContainsEscape: Bool
}

struct Phase2FinalJSONParser {
    enum Failure: Error, Equatable {
        case malformed
        case duplicateKey
        case resourceLimit
    }

    static let maximumDepth = 8
    static let maximumLexicalTokens = 4_096
    static let maximumAggregateEntries = 512

    private let bytes: [UInt8]
    private let maximumAggregateEntries: Int
    private var index = 0
    private var lexicalTokens = 0
    private var aggregateEntries = 0

    init(data: Data, maximumAggregateEntries: Int = Self.maximumAggregateEntries) {
        bytes = Array(data)
        self.maximumAggregateEntries = maximumAggregateEntries
    }

    mutating func parse() throws -> Phase2FinalJSONValue {
        skipWhitespace()
        let value = try parseValue(depth: 1)
        skipWhitespace()
        guard index == bytes.count else { throw Failure.malformed }
        return value
    }

    private mutating func parseValue(depth: Int) throws -> Phase2FinalJSONValue {
        guard depth <= Self.maximumDepth else { throw Failure.resourceLimit }
        skipWhitespace()
        guard index < bytes.count else { throw Failure.malformed }
        switch bytes[index] {
        case UInt8(ascii: "{"):
            return try parseObject(depth: depth)
        case UInt8(ascii: "["):
            return try parseArray(depth: depth)
        case UInt8(ascii: "\""):
            return .string(try parseString())
        case UInt8(ascii: "t"):
            try parseLiteral("true")
            return .boolean
        case UInt8(ascii: "f"):
            try parseLiteral("false")
            return .boolean
        case UInt8(ascii: "n"):
            try parseLiteral("null")
            return .null
        case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"):
            try parseNumber()
            return .number
        default:
            throw Failure.malformed
        }
    }

    private mutating func parseObject(depth: Int) throws -> Phase2FinalJSONValue {
        try consumeToken(UInt8(ascii: "{"))
        skipWhitespace()
        if try consumeOptionalToken(UInt8(ascii: "}")) { return .object([:]) }

        var object: [String: Phase2FinalJSONValue] = [:]
        while true {
            skipWhitespace()
            guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else {
                throw Failure.malformed
            }
            let key = try parseString().value
            guard object[key] == nil else { throw Failure.duplicateKey }
            skipWhitespace()
            try consumeToken(UInt8(ascii: ":"))
            let value = try parseValue(depth: depth + 1)
            try recordAggregateEntry()
            object[key] = value
            skipWhitespace()
            if try consumeOptionalToken(UInt8(ascii: "}")) { return .object(object) }
            try consumeToken(UInt8(ascii: ","))
        }
    }

    private mutating func parseArray(depth: Int) throws -> Phase2FinalJSONValue {
        try consumeToken(UInt8(ascii: "["))
        skipWhitespace()
        if try consumeOptionalToken(UInt8(ascii: "]")) { return .array([]) }

        var values: [Phase2FinalJSONValue] = []
        while true {
            values.append(try parseValue(depth: depth + 1))
            try recordAggregateEntry()
            skipWhitespace()
            if try consumeOptionalToken(UInt8(ascii: "]")) { return .array(values) }
            try consumeToken(UInt8(ascii: ","))
        }
    }

    private mutating func parseString() throws -> Phase2FinalJSONString {
        let start = index
        guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else {
            throw Failure.malformed
        }
        index += 1
        var escaped = false
        var sourceContainsEscape = false
        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            if escaped {
                escaped = false
                continue
            }
            if byte == UInt8(ascii: "\\") {
                escaped = true
                sourceContainsEscape = true
            } else if byte == UInt8(ascii: "\"") {
                try recordToken()
                let encoded = Data(bytes[start..<index])
                guard let value = try? JSONDecoder().decode(String.self, from: encoded) else {
                    throw Failure.malformed
                }
                return .init(value: value, sourceContainsEscape: sourceContainsEscape)
            } else if byte < 0x20 {
                throw Failure.malformed
            }
        }
        throw Failure.malformed
    }

    private mutating func parseLiteral(_ literal: String) throws {
        let expected = Array(literal.utf8)
        guard index + expected.count <= bytes.count,
              Array(bytes[index..<(index + expected.count)]) == expected
        else { throw Failure.malformed }
        index += expected.count
        try recordToken()
    }

    private mutating func parseNumber() throws {
        let start = index
        if consumeRaw(UInt8(ascii: "-")) {}
        if consumeRaw(UInt8(ascii: "0")) {
            guard index == bytes.count || !(UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[index]) else {
                throw Failure.malformed
            }
        } else {
            guard consumeDigit(in: UInt8(ascii: "1")...UInt8(ascii: "9")) else { throw Failure.malformed }
            while consumeDigit(in: UInt8(ascii: "0")...UInt8(ascii: "9")) {}
        }
        if consumeRaw(UInt8(ascii: ".")) {
            guard consumeDigit(in: UInt8(ascii: "0")...UInt8(ascii: "9")) else { throw Failure.malformed }
            while consumeDigit(in: UInt8(ascii: "0")...UInt8(ascii: "9")) {}
        }
        if consumeRaw(UInt8(ascii: "e")) || consumeRaw(UInt8(ascii: "E")) {
            if !consumeRaw(UInt8(ascii: "+")) { _ = consumeRaw(UInt8(ascii: "-")) }
            guard consumeDigit(in: UInt8(ascii: "0")...UInt8(ascii: "9")) else { throw Failure.malformed }
            while consumeDigit(in: UInt8(ascii: "0")...UInt8(ascii: "9")) {}
        }
        guard index > start else { throw Failure.malformed }
        try recordToken()
    }

    private mutating func recordAggregateEntry() throws {
        aggregateEntries += 1
        guard aggregateEntries <= maximumAggregateEntries else { throw Failure.resourceLimit }
    }

    private mutating func recordToken() throws {
        lexicalTokens += 1
        guard lexicalTokens <= Self.maximumLexicalTokens else { throw Failure.resourceLimit }
    }

    private mutating func consumeToken(_ expected: UInt8) throws {
        guard consumeRaw(expected) else { throw Failure.malformed }
        try recordToken()
    }

    private mutating func consumeOptionalToken(_ expected: UInt8) throws -> Bool {
        guard consumeRaw(expected) else { return false }
        try recordToken()
        return true
    }

    private mutating func consumeRaw(_ expected: UInt8) -> Bool {
        guard index < bytes.count, bytes[index] == expected else { return false }
        index += 1
        return true
    }

    private mutating func consumeDigit(in range: ClosedRange<UInt8>) -> Bool {
        guard index < bytes.count, range.contains(bytes[index]) else { return false }
        index += 1
        return true
    }

    private mutating func skipWhitespace() {
        while index < bytes.count, [9, 10, 13, 32].contains(bytes[index]) { index += 1 }
    }
}

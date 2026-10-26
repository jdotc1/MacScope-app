import Foundation

/// Caller-supplied identifiers only. This value establishes neither document installation
/// authority nor image/source binding; the eventual transaction owner must check those fences.
struct AnalystFindingRevisionIdentity: Equatable, Sendable {
    let findingID: UUID
    let workspaceID: UUID
    let documentID: UUID
}

struct AnalystFindingRevisionVector: Equatable, Sendable {
    let content: UInt64
    let review: UInt64
}

/// One explicit opaque review action, retained even after its content revision becomes historical.
struct AnalystFindingReviewBinding<Decision: Equatable & Sendable>: Equatable, Sendable {
    let decision: Decision
    let contentRevision: UInt64
    let reviewRevision: UInt64
    let previousReviewRevision: UInt64?
}

/// An in-memory revision value, not a persistence schema. Content and Decision remain caller-owned
/// values: no authored-kind, evidence-classification, rich-text or freshness taxonomy is imposed.
struct AnalystFindingRevisionState<Content: Equatable & Sendable, Decision: Equatable & Sendable>: Equatable, Sendable {
    let identity: AnalystFindingRevisionIdentity
    let content: Content
    let revisions: AnalystFindingRevisionVector
    let review: AnalystFindingReviewBinding<Decision>?

    /// A revision-bound decision may be a rejection. Current never implies endorsement, source
    /// freshness, observation status or evidence admission.
    var isReviewCurrent: Bool { review?.contentRevision == revisions.content }

    init(identity: AnalystFindingRevisionIdentity, content: Content) {
        self.identity = identity
        self.content = content
        self.revisions = .init(content: 1, review: 0)
        self.review = nil
    }

    /// Validates a supplied value without reading, loading or admitting a durable record.
    init(identity: AnalystFindingRevisionIdentity, content: Content,
         revisions: AnalystFindingRevisionVector, review: AnalystFindingReviewBinding<Decision>?) throws {
        guard revisions.content > 0 else { throw AnalystFindingRevisionError.invalidState }
        if let review {
            guard revisions.review > 0,
                  review.reviewRevision == revisions.review,
                  review.contentRevision > 0, review.contentRevision <= revisions.content,
                  review.previousReviewRevision == (revisions.review == 1 ? nil : revisions.review - 1) else {
                throw AnalystFindingRevisionError.invalidState
            }
        } else {
            guard revisions.review == 0 else { throw AnalystFindingRevisionError.invalidState }
        }
        self.identity = identity
        self.content = content
        self.revisions = revisions
        self.review = review
    }
}

/// One complete before/after receipt. This type accumulates no history and confers no commit
/// authority. Full history requires the existing owner to retain each receipt atomically.
/// Generic payloads are copied by value, not deep-cloned if callers supply reference-backed data.
struct AnalystFindingRevisionTransition<Content: Equatable & Sendable, Decision: Equatable & Sendable>: Equatable, Sendable {
    let before: AnalystFindingRevisionState<Content, Decision>
    let after: AnalystFindingRevisionState<Content, Decision>
}

enum AnalystFindingRevisionError: Error, Equatable {
    case invalidState
    case identityMismatch
    case staleRevision(expected: AnalystFindingRevisionVector, actual: AnalystFindingRevisionVector)
    case unchangedContent
    case contentRevisionExhausted
    case reviewRevisionExhausted
}

/// Pure copy-in/copy-out transitions. No storage, mutable cache, UUID generation, hashing,
/// model invocation or source lookup. The caller must enforce installation and commit fences.
enum AnalystFindingRevision {
    static func applyContentEdit<Content: Equatable & Sendable, Decision: Equatable & Sendable>(
        current: AnalystFindingRevisionState<Content, Decision>,
        identity: AnalystFindingRevisionIdentity,
        expected: AnalystFindingRevisionVector,
        replacement: Content
    ) throws -> AnalystFindingRevisionTransition<Content, Decision> {
        try requirePrecondition(currentIdentity: current.identity, revisions: current.revisions,
                                identity: identity, expected: expected)
        guard replacement != current.content else { throw AnalystFindingRevisionError.unchangedContent }
        guard current.revisions.content < UInt64.max else {
            throw AnalystFindingRevisionError.contentRevisionExhausted
        }
        let after = try AnalystFindingRevisionState<Content, Decision>(identity: current.identity,
            content: replacement,
            revisions: .init(content: current.revisions.content + 1, review: current.revisions.review),
            review: current.review)
        // Keep the original binding and opaque decision. The increment alone makes it historical;
        // derived invalidation is not an explicit review action and does not consume a review ID.
        return .init(before: current, after: after)
    }

    static func applyReview<Content: Equatable & Sendable, Decision: Equatable & Sendable>(
        current: AnalystFindingRevisionState<Content, Decision>,
        identity: AnalystFindingRevisionIdentity,
        expected: AnalystFindingRevisionVector,
        decision: Decision
    ) throws -> AnalystFindingRevisionTransition<Content, Decision> {
        try requirePrecondition(currentIdentity: current.identity, revisions: current.revisions,
                                identity: identity, expected: expected)
        guard current.revisions.review < UInt64.max else {
            throw AnalystFindingRevisionError.reviewRevisionExhausted
        }
        let nextReview = current.revisions.review + 1
        let after = try AnalystFindingRevisionState<Content, Decision>(identity: current.identity,
            content: current.content,
            revisions: .init(content: current.revisions.content, review: nextReview),
            review: .init(decision: decision, contentRevision: current.revisions.content,
                reviewRevision: nextReview,
                previousReviewRevision: current.revisions.review == 0 ? nil : current.revisions.review))
        // Equal decisions are still distinct explicit actions. The before state retains the
        // prior decision; complete historical content/decisions require the caller's history owner.
        return .init(before: current, after: after)
    }

    private static func requirePrecondition(currentIdentity: AnalystFindingRevisionIdentity,
                                           revisions: AnalystFindingRevisionVector,
                                           identity: AnalystFindingRevisionIdentity,
                                           expected: AnalystFindingRevisionVector) throws {
        guard currentIdentity == identity else { throw AnalystFindingRevisionError.identityMismatch }
        guard expected == revisions else {
            throw AnalystFindingRevisionError.staleRevision(expected: expected, actual: revisions)
        }
    }
}

/// A finding's reference to one navigator contract fact. `id` is the fact's content id. `generation` is
/// the analysis generation the fact carried when the finding was written, and `slot` names the image
/// whose navigator state holds it. Both are optional: a citation without a generation is checked for
/// presence only, and one without a slot is looked up in every slot the support check is given.
/// Citations say what a finding rests on; they never say the finding is right.
struct FactCitation: Hashable, Codable, Sendable {
    static let maximumIDBytes = 256
    let id: String
    let generation: NavigatorGeneration?
    let slot: ImageSlot?

    init(id: String, generation: NavigatorGeneration? = nil, slot: ImageSlot? = nil) {
        self.id = id; self.generation = generation; self.slot = slot
    }

    private enum CodingKeys: String, CodingKey, CaseIterable { case id, generation, slot }

    /// Strict like the history decoders: an unknown key is a newer writer, not something to drop.
    init(from decoder: Decoder) throws {
        let keys = try decoder.container(keyedBy: FactCitationAnyKey.self)
        guard Set(keys.allKeys.map(\.stringValue)).isSubset(of: Set(CodingKeys.allCases.map(\.rawValue))) else {
            throw AnalystFindingError.invalidContent
        }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        generation = try values.decodeIfPresent(NavigatorGeneration.self, forKey: .generation)
        slot = try values.decodeIfPresent(ImageSlot.self, forKey: .slot)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encodeIfPresent(generation, forKey: .generation)
        try values.encodeIfPresent(slot, forKey: .slot)
    }

    func validate() throws {
        guard !id.isEmpty, id.utf8.count <= Self.maximumIDBytes,
              id.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7F }) else {
            throw AnalystFindingError.invalidContent
        }
        if let generation {
            guard !generation.imageIdentity.isEmpty, !generation.inputKey.isEmpty,
                  !generation.knowledgeVersion.isEmpty else { throw AnalystFindingError.invalidContent }
        }
        if let slot { guard slot.rawValue >= 0 else { throw AnalystFindingError.invalidContent } }
    }

    /// Validates a record's whole citation list: bounded, each citation well formed, and no fact cited twice
    /// for the same slot.
    static func validate(_ citations: [FactCitation]) throws {
        guard citations.count <= AnalystFindingRecord.maximumCitations else { throw AnalystFindingError.bounds }
        var seen = Set<String>()
        for citation in citations {
            try citation.validate()
            guard seen.insert("\(citation.slot?.rawValue ?? -1)/\(citation.id)").inserted else {
                throw AnalystFindingError.invalidContent
            }
        }
    }
}

private struct FactCitationAnyKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

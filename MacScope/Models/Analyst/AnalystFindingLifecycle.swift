import Foundation

enum AnalystFindingLifecycleError: Error, LocalizedError {
    case staleEditor
    var errorDescription: String? {
        "The finding or document changed while this editor was open. Reload the finding before editing or reviewing it."
    }
}

/// Decisions describe authored interpretation only. They never attest to source freshness.
enum AnalystFindingReviewDecision: String, Codable, CaseIterable, Sendable {
    case reviewed, needsChanges
}

struct AnalystFindingSavedReview: Codable, Equatable, Sendable {
    let decision: AnalystFindingReviewDecision
    let contentRevision: UInt64
    let reviewRevision: UInt64
    let previousReviewRevision: UInt64?

    init(_ value: AnalystFindingReviewBinding<AnalystFindingReviewDecision>) {
        decision = value.decision; contentRevision = value.contentRevision
        reviewRevision = value.reviewRevision; previousReviewRevision = value.previousReviewRevision
    }
    var binding: AnalystFindingReviewBinding<AnalystFindingReviewDecision> {
        .init(decision: decision, contentRevision: contentRevision, reviewRevision: reviewRevision,
              previousReviewRevision: previousReviewRevision)
    }
}

/// Why the system marked a finding stale. Each reason names the evidence that stopped supporting it;
/// none of them says the authored text is wrong.
enum AnalystFindingStaleReason: String, Codable, CaseIterable, Sendable {
    /// A cited contract fact is stale (generation fenced), reverted or no longer present.
    case factStale
    /// The image a citation was made against has a different identity now.
    case imageChanged
    /// An annotation a cited fact depends on was reverted.
    case premiseReverted

    var detail: String {
        switch self {
        case .factStale: "A cited fact is stale, reverted or no longer present."
        case .imageChanged: "The image this finding was written against has changed."
        case .premiseReverted: "An annotation this finding depends on was reverted."
        }
    }
}

/// What the analyst sees about a finding's standing. A retraction outranks staleness.
enum AnalystFindingStanding: Equatable, Sendable {
    case active
    case stale(AnalystFindingStaleReason)
    case retracted(reason: String)

    var label: String {
        switch self {
        case .active: "Active"
        case .stale: "Stale"
        case .retracted: "Retracted"
        }
    }
    var detail: String? {
        switch self {
        case .active: nil
        case .stale(let reason): reason.detail
        case .retracted(let reason): reason
        }
    }
    var isRetracted: Bool { if case .retracted = self { return true } else { return false } }
    var isStale: Bool { if case .stale = self { return true } else { return false } }
}

/// The latest reducer binding is never discarded. Undo/redo can select an earlier review (or
/// none), but cannot rebind that decision to a different content revision.
struct AnalystFindingAuthoredState: Codable, Equatable, Sendable {
    let text: String
    let contentRevision: UInt64
    let reviewRevision: UInt64
    let latestReview: AnalystFindingSavedReview?
    let selectedReviewRevision: UInt64?
    /// Set by the system when cited evidence stops supporting the finding; cleared only by `readmit`.
    /// Independent of the authored text, so it does not move the content or review revisions.
    let staleReason: AnalystFindingStaleReason?
    /// Set by `retract`; cleared only by undoing the retraction. Outranks `staleReason` for display.
    let retractionReason: String?

    init(text: String) {
        self.text = text; contentRevision = 1; reviewRevision = 0
        latestReview = nil; selectedReviewRevision = nil
        staleReason = nil; retractionReason = nil
    }
    init(_ value: AnalystFindingRevisionState<String, AnalystFindingReviewDecision>, selectedReview: UInt64?,
         staleReason: AnalystFindingStaleReason?, retractionReason: String?) {
        text = value.content; contentRevision = value.revisions.content; reviewRevision = value.revisions.review
        latestReview = value.review.map(AnalystFindingSavedReview.init); selectedReviewRevision = selectedReview
        self.staleReason = staleReason; self.retractionReason = retractionReason
    }
    /// The same authored text and review state with a different standing.
    func replacingStanding(staleReason: AnalystFindingStaleReason?, retractionReason: String?) -> Self {
        .init(text: text, contentRevision: contentRevision, reviewRevision: reviewRevision, latestReview: latestReview,
              selectedReviewRevision: selectedReviewRevision, staleReason: staleReason, retractionReason: retractionReason)
    }
    private init(text: String, contentRevision: UInt64, reviewRevision: UInt64, latestReview: AnalystFindingSavedReview?,
                 selectedReviewRevision: UInt64?, staleReason: AnalystFindingStaleReason?, retractionReason: String?) {
        self.text = text; self.contentRevision = contentRevision; self.reviewRevision = reviewRevision
        self.latestReview = latestReview; self.selectedReviewRevision = selectedReviewRevision
        self.staleReason = staleReason; self.retractionReason = retractionReason
    }
    var standing: AnalystFindingStanding {
        if let retractionReason { return .retracted(reason: retractionReason) }
        if let staleReason { return .stale(staleReason) }
        return .active
    }
    var vector: AnalystFindingRevisionVector { .init(content: contentRevision, review: reviewRevision) }
    func reducerState(identity: AnalystFindingRevisionIdentity) throws -> AnalystFindingRevisionState<String, AnalystFindingReviewDecision> {
        guard !text.isEmpty, text.utf8.count <= 65_536 else {
            throw AnalystFindingError.invalidContent
        }
        return try .init(identity: identity, content: text, revisions: vector, review: latestReview?.binding)
    }
}

struct AnalystFindingHistoryOperation: Codable, Equatable, Sendable {
    /// `retract` and `readmit` are analyst actions and sit on the undo stack beside edit and review.
    /// `stale` is a system action: it never enters the undo or redo stack and has no inverse.
    enum Kind: String, Codable, Sendable { case edit, review, undo, redo, retract, stale, readmit }
    let kind: Kind
    let replacementText: String?
    let decision: AnalystFindingReviewDecision?
    let targetSequence: Int?
    let reason: String?
    let staleReason: AnalystFindingStaleReason?

    init(kind: Kind, replacementText: String?, decision: AnalystFindingReviewDecision?, targetSequence: Int?,
         reason: String? = nil, staleReason: AnalystFindingStaleReason? = nil) {
        self.kind = kind; self.replacementText = replacementText; self.decision = decision
        self.targetSequence = targetSequence; self.reason = reason; self.staleReason = staleReason
    }

    static func edit(_ text: String) -> Self { .init(kind: .edit, replacementText: text, decision: nil, targetSequence: nil) }
    static func review(_ decision: AnalystFindingReviewDecision) -> Self {
        .init(kind: .review, replacementText: nil, decision: decision, targetSequence: nil)
    }
    static func undo(_ target: Int) -> Self { .init(kind: .undo, replacementText: nil, decision: nil, targetSequence: target) }
    static func redo(_ target: Int) -> Self { .init(kind: .redo, replacementText: nil, decision: nil, targetSequence: target) }
    static func retract(_ reason: String) -> Self {
        .init(kind: .retract, replacementText: nil, decision: nil, targetSequence: nil, reason: reason)
    }
    static func stale(_ reason: AnalystFindingStaleReason) -> Self {
        .init(kind: .stale, replacementText: nil, decision: nil, targetSequence: nil, staleReason: reason)
    }
    static var readmit: Self { .init(kind: .readmit, replacementText: nil, decision: nil, targetSequence: nil) }
}

struct AnalystFindingHistoryEntry: Codable, Equatable, Identifiable, Sendable {
    let sequence: Int
    /// Reference-date seconds, independent of enclosing package Date strategies.
    let recordedAt: Double
    let operation: AnalystFindingHistoryOperation
    let before: AnalystFindingAuthoredState
    let after: AnalystFindingAuthoredState
    var id: Int { sequence }
}

/// Versioned, complete authored history; original request/candidate/context stay in the record.
/// Validation replays the pure reducer and the command stacks, not rendered text or provenance.
struct AnalystFindingLifecycle: Codable, Equatable, Sendable {
    /// Authored operations retain the existing 256-entry limit. One terminal system stale
    /// entry is reserved beyond it; it cannot admit a later authored operation.
    static let maximumHistoryEntries = 256
    /// UTF-8 byte bound for a retraction reason, measured after trimming surrounding whitespace.
    static let maximumReasonBytes = 1_024
    let schemaVersion: Int
    let state: AnalystFindingAuthoredState
    let history: [AnalystFindingHistoryEntry]

    init(initialText: String) {
        schemaVersion = 1; state = .init(text: initialText); history = []
    }
    private init(state: AnalystFindingAuthoredState, history: [AnalystFindingHistoryEntry]) {
        schemaVersion = 1; self.state = state; self.history = history
    }

    var selectedReview: AnalystFindingSavedReview? {
        guard let revision = state.selectedReviewRevision else { return nil }
        return history.first(where: { $0.after.latestReview?.reviewRevision == revision })?.after.latestReview
    }
    var isReviewCurrent: Bool { selectedReview?.contentRevision == state.contentRevision }
    var standing: AnalystFindingStanding { state.standing }

    /// True when applying `operation` would clear a stale mark: a `readmit`, or a redo of one. The
    /// store runs the semantic support check before it applies such an operation, so neither the
    /// analyst's readmit nor a redo of it can bring back a finding whose citations still fail.
    func clearsStaleness(_ operation: AnalystFindingHistoryOperation) -> Bool {
        switch operation.kind {
        case .readmit: return true
        case .redo:
            guard let target = operation.targetSequence, target > 0, target <= history.count else { return false }
            return history[target - 1].operation.kind == .readmit
        default: return false
        }
    }

    func validate(initialText: String, identity: AnalystFindingRevisionIdentity) throws {
        guard schemaVersion == 1 else { throw AnalystFindingError.unsupportedSchema(schemaVersion) }
        guard history.count <= Self.maximumHistoryEntries
            || (history.count == Self.maximumHistoryEntries + 1 && history.last?.operation.kind == .stale) else {
            throw AnalystFindingError.bounds
        }
        var replay = AnalystFindingLifecycle(initialText: initialText)
        var undo: [Int] = [], redo: [Int] = []
        for entry in history {
            guard entry.sequence == replay.history.count + 1, entry.recordedAt.isFinite,
                  entry.before == replay.state else { throw AnalystFindingError.unsupportedRevisionState }
            let next = try replay.transition(entry.operation, identity: identity, undo: &undo, redo: &redo)
            guard entry.after == next else { throw AnalystFindingError.unsupportedRevisionState }
            replay = .init(state: next, history: replay.history + [entry])
        }
        guard replay.state == state else { throw AnalystFindingError.unsupportedRevisionState }
        _ = try state.reducerState(identity: identity)
    }

    func applying(_ operation: AnalystFindingHistoryOperation, identity: AnalystFindingRevisionIdentity,
                  initialText: String, expected: AnalystFindingRevisionVector, now: Date) throws -> Self {
        try validate(initialText: initialText, identity: identity)
        guard expected == state.vector else {
            throw AnalystFindingRevisionError.staleRevision(expected: expected, actual: state.vector)
        }
        let canAppend = history.count < Self.maximumHistoryEntries
            || (history.count == Self.maximumHistoryEntries && operation.kind == .stale)
        guard canAppend, now.timeIntervalSinceReferenceDate.isFinite else {
            throw AnalystFindingError.bounds
        }
        var stacks = commandStacks()
        let after = try transition(operation, identity: identity, undo: &stacks.undo, redo: &stacks.redo)
        return .init(state: after, history: history + [.init(sequence: history.count + 1,
            recordedAt: now.timeIntervalSinceReferenceDate, operation: operation, before: state, after: after)])
    }

    private func commandStacks() -> (undo: [Int], redo: [Int]) {
        var undo: [Int] = [], redo: [Int] = []
        for entry in history {
            switch entry.operation.kind {
            case .edit, .review, .retract, .readmit: undo.append(entry.sequence); redo.removeAll()
            case .undo: if let target = undo.popLast() { redo.append(target) }
            case .redo: if let target = redo.popLast() { undo.append(target) }
            case .stale: break
            }
        }
        return (undo, redo)
    }

    private func transition(_ operation: AnalystFindingHistoryOperation, identity: AnalystFindingRevisionIdentity,
                            undo: inout [Int], redo: inout [Int]) throws -> AnalystFindingAuthoredState {
        let current = try state.reducerState(identity: identity)
        switch operation.kind {
        case .edit:
            guard let text = operation.replacementText, operation.decision == nil, operation.targetSequence == nil,
                  operation.reason == nil, operation.staleReason == nil else {
                throw AnalystFindingError.invalidContent
            }
            // A retracted finding is frozen: edit and review wait for the retraction to be undone.
            guard state.retractionReason == nil else { throw AnalystFindingError.retracted }
            let result = try AnalystFindingRevision.applyContentEdit(current: current, identity: identity,
                expected: state.vector, replacement: text)
            let next = AnalystFindingAuthoredState(result.after, selectedReview: state.selectedReviewRevision,
                staleReason: state.staleReason, retractionReason: state.retractionReason)
            _ = try next.reducerState(identity: identity)
            undo.append(history.count + 1); redo.removeAll()
            return next
        case .review:
            guard let decision = operation.decision, operation.replacementText == nil, operation.targetSequence == nil,
                  operation.reason == nil, operation.staleReason == nil else {
                throw AnalystFindingError.invalidContent
            }
            guard state.retractionReason == nil else { throw AnalystFindingError.retracted }
            let result = try AnalystFindingRevision.applyReview(current: current, identity: identity,
                expected: state.vector, decision: decision)
            undo.append(history.count + 1); redo.removeAll()
            return .init(result.after, selectedReview: result.after.revisions.review,
                staleReason: state.staleReason, retractionReason: state.retractionReason)
        case .retract:
            // Legal from active or stale; a second retraction of a retracted finding is not.
            guard let raw = operation.reason, operation.replacementText == nil, operation.decision == nil,
                  operation.targetSequence == nil, operation.staleReason == nil else {
                throw AnalystFindingError.invalidContent
            }
            guard state.retractionReason == nil else { throw AnalystFindingError.invalidStanding }
            let reason = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !reason.isEmpty, reason.utf8.count <= Self.maximumReasonBytes else {
                throw AnalystFindingError.invalidContent
            }
            undo.append(history.count + 1); redo.removeAll()
            return state.replacingStanding(staleReason: state.staleReason, retractionReason: reason)
        case .stale:
            // System action. Legal while active, and while retracted so the mark survives an undo of the
            // retraction; never legal twice in a row, and it leaves both command stacks alone.
            guard let reason = operation.staleReason, operation.replacementText == nil, operation.decision == nil,
                  operation.targetSequence == nil, operation.reason == nil else {
                throw AnalystFindingError.invalidContent
            }
            guard state.staleReason == nil else { throw AnalystFindingError.invalidStanding }
            return state.replacingStanding(staleReason: reason, retractionReason: state.retractionReason)
        case .readmit:
            // Analyst action. Legal only from stale and not while retracted. The store additionally
            // requires the semantic support check to pass (`clearsStaleness`).
            guard operation.replacementText == nil, operation.decision == nil, operation.targetSequence == nil,
                  operation.reason == nil, operation.staleReason == nil else {
                throw AnalystFindingError.invalidContent
            }
            guard state.retractionReason == nil else { throw AnalystFindingError.retracted }
            guard state.staleReason != nil else { throw AnalystFindingError.invalidStanding }
            undo.append(history.count + 1); redo.removeAll()
            return state.replacingStanding(staleReason: nil, retractionReason: nil)
        case .undo, .redo:
            guard operation.replacementText == nil, operation.decision == nil,
                  operation.reason == nil, operation.staleReason == nil,
                  let target = operation.targetSequence, target > 0, target <= history.count,
                  (operation.kind == .undo ? undo.last : redo.last) == target else {
                throw AnalystFindingError.unsupportedRevisionState
            }
            let original = history[target - 1]
            let desired = operation.kind == .undo ? original.before : original.after
            let result: AnalystFindingAuthoredState
            switch original.operation.kind {
            case .edit, .review:
                guard state.retractionReason == nil else { throw AnalystFindingError.retracted }
                let next: AnalystFindingRevisionState<String, AnalystFindingReviewDecision>
                if desired.text == state.text { next = current }
                else {
                    next = try AnalystFindingRevision.applyContentEdit(current: current, identity: identity,
                        expected: state.vector, replacement: desired.text).after
                }
                // Restore selection, never the old counters or a freshly rebound review. An edit
                // undone after review therefore still requires a new explicit review of its text.
                // Standing is not authored history: it keeps whatever the finding has now.
                result = .init(next, selectedReview: desired.selectedReviewRevision,
                    staleReason: state.staleReason, retractionReason: state.retractionReason)
            case .retract:
                // Only the retraction moves; a stale mark added in between stays.
                result = state.replacingStanding(staleReason: state.staleReason,
                                                 retractionReason: desired.retractionReason)
            case .readmit:
                // Only the stale mark moves; a retraction is never touched by undoing a readmit.
                result = state.replacingStanding(staleReason: desired.staleReason,
                                                 retractionReason: state.retractionReason)
            case .stale, .undo, .redo:
                throw AnalystFindingError.unsupportedRevisionState
            }
            if operation.kind == .undo { undo.removeLast(); redo.append(target) }
            else { redo.removeLast(); undo.append(target) }
            return result
        }
    }
}

extension AnalystFindingRecord {
    var revisionIdentity: AnalystFindingRevisionIdentity {
        .init(findingID: id, workspaceID: workspaceID, documentID: documentID)
    }
    var authoredLifecycle: AnalystFindingLifecycle { lifecycle ?? .init(initialText: content.candidateText) }
    var authoredText: String { authoredLifecycle.state.text }
    var standing: AnalystFindingStanding { authoredLifecycle.standing }
}

extension AnalystFindingSavedReview {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case decision, contentRevision, reviewRevision, previousReviewRevision
    }
    init(from decoder: Decoder) throws {
        try requireAnalystFindingHistoryKeys(decoder, allowed: Set(CodingKeys.allCases.map(\.rawValue)))
        let values = try decoder.container(keyedBy: CodingKeys.self)
        decision = try values.decode(AnalystFindingReviewDecision.self, forKey: .decision)
        contentRevision = try values.decode(UInt64.self, forKey: .contentRevision)
        reviewRevision = try values.decode(UInt64.self, forKey: .reviewRevision)
        previousReviewRevision = try values.decodeIfPresent(UInt64.self, forKey: .previousReviewRevision)
    }
}

extension AnalystFindingAuthoredState {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case text, contentRevision, reviewRevision, latestReview, selectedReviewRevision
        case staleReason, retractionReason
    }
    init(from decoder: Decoder) throws {
        try requireAnalystFindingHistoryKeys(decoder, allowed: Set(CodingKeys.allCases.map(\.rawValue)))
        let values = try decoder.container(keyedBy: CodingKeys.self)
        text = try values.decode(String.self, forKey: .text)
        contentRevision = try values.decode(UInt64.self, forKey: .contentRevision)
        reviewRevision = try values.decode(UInt64.self, forKey: .reviewRevision)
        latestReview = try values.decodeIfPresent(AnalystFindingSavedReview.self, forKey: .latestReview)
        selectedReviewRevision = try values.decodeIfPresent(UInt64.self, forKey: .selectedReviewRevision)
        staleReason = try values.decodeIfPresent(AnalystFindingStaleReason.self, forKey: .staleReason)
        retractionReason = try values.decodeIfPresent(String.self, forKey: .retractionReason)
    }
}

extension AnalystFindingHistoryOperation {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case kind, replacementText, decision, targetSequence, reason, staleReason
    }
    init(from decoder: Decoder) throws {
        try requireAnalystFindingHistoryKeys(decoder, allowed: Set(CodingKeys.allCases.map(\.rawValue)))
        let values = try decoder.container(keyedBy: CodingKeys.self)
        kind = try values.decode(Kind.self, forKey: .kind)
        replacementText = try values.decodeIfPresent(String.self, forKey: .replacementText)
        decision = try values.decodeIfPresent(AnalystFindingReviewDecision.self, forKey: .decision)
        targetSequence = try values.decodeIfPresent(Int.self, forKey: .targetSequence)
        reason = try values.decodeIfPresent(String.self, forKey: .reason)
        staleReason = try values.decodeIfPresent(AnalystFindingStaleReason.self, forKey: .staleReason)
    }
}

extension AnalystFindingHistoryEntry {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case sequence, recordedAt, operation, before, after
    }
    init(from decoder: Decoder) throws {
        try requireAnalystFindingHistoryKeys(decoder, allowed: Set(CodingKeys.allCases.map(\.rawValue)))
        let values = try decoder.container(keyedBy: CodingKeys.self)
        sequence = try values.decode(Int.self, forKey: .sequence)
        recordedAt = try values.decode(Double.self, forKey: .recordedAt)
        operation = try values.decode(AnalystFindingHistoryOperation.self, forKey: .operation)
        before = try values.decode(AnalystFindingAuthoredState.self, forKey: .before)
        after = try values.decode(AnalystFindingAuthoredState.self, forKey: .after)
    }
}

extension AnalystFindingLifecycle {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion, state, history
    }
    init(from decoder: Decoder) throws {
        try requireAnalystFindingHistoryKeys(decoder, allowed: Set(CodingKeys.allCases.map(\.rawValue)))
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        state = try values.decode(AnalystFindingAuthoredState.self, forKey: .state)
        history = try values.decode([AnalystFindingHistoryEntry].self, forKey: .history)
    }
}

private struct AnalystFindingHistoryKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}
private func requireAnalystFindingHistoryKeys(_ decoder: Decoder, allowed: Set<String>) throws {
    let all = try decoder.container(keyedBy: AnalystFindingHistoryKey.self)
    guard Set(all.allKeys.map(\.stringValue)).isSubset(of: allowed) else {
        throw AnalystFindingError.unsupportedRevisionState
    }
}

import Foundation

/// What a finding's citations amount to against the live navigator state.
///
/// - `supported`: the cited fact (or annotation) is live and, when the citation carries a generation,
///   still has that generation.
/// - `unsupported`: nothing with that id exists in the state the citation points at.
/// - `stale`: it exists but no longer counts: it was reverted, fenced by a newer analysis, lost a premise,
///   or the image or generation it was cited against has changed.
/// - `conflicting`: live facts the finding cites that disagree on a single-valued predicate of one
///   subject. Both citations are reported; neither is hidden behind the other.
///
/// Support is about the evidence a finding rests on. It never says the authored text is right.
struct SupportResult: Equatable, Sendable {
    var supported: [FactCitation] = []
    var unsupported: [FactCitation] = []
    var stale: [FactCitation] = []
    var conflicting: [FactCitation] = []
    /// Why each stale citation is stale. Unsupported citations have no entry and count as `factStale`.
    var causes: [FactCitation: AnalystFindingStaleReason] = [:]

    /// True when at least one citation is absent or stale, which is what marks a finding stale.
    var invalidates: Bool { !unsupported.isEmpty || !stale.isEmpty }

    /// True when every citation is supported and none conflicts. Readmission requires it.
    var isFullySupported: Bool { !invalidates && conflicting.isEmpty }

    /// The reason to record when the finding is marked stale. When several apply, a changed image
    /// outranks a reverted premise, which outranks a stale or missing fact.
    var staleReason: AnalystFindingStaleReason? {
        let reasons = Set((unsupported + stale).map { causes[$0] ?? .factStale })
        guard !reasons.isEmpty else { return nil }
        for reason in [AnalystFindingStaleReason.imageChanged, .premiseReverted, .factStale]
        where reasons.contains(reason) { return reason }
        return nil
    }
}

/// The navigator state a support check reads: one contract store per image slot, plus the identity string
/// each slot's image has now. Hand-built in tests; built from the workspace bridge in the app.
struct AnalystFindingSupportSource: Sendable {
    var stores: [ImageSlot: NavigatorContractStore]
    var imageIdentities: [ImageSlot: String]

    init(stores: [ImageSlot: NavigatorContractStore] = [:], imageIdentities: [ImageSlot: String] = [:]) {
        self.stores = stores; self.imageIdentities = imageIdentities
    }
    var slots: [ImageSlot] { stores.keys.sorted() }
}

/// A finding that should be marked stale, and why.
struct AnalystFindingStaleMark: Equatable, Sendable {
    let findingID: UUID
    let reason: AnalystFindingStaleReason
}

enum AnalystFindingSupport {
    /// Compares `citations` with `source`. A citation with a slot is looked up in that slot only; one
    /// without is looked up in every slot, in slot order, and the first slot that knows the id decides.
    static func check(_ citations: [FactCitation], source: AnalystFindingSupportSource) -> SupportResult {
        var result = SupportResult()
        var liveFacts: [(citation: FactCitation, fact: NavigatorFact)] = []
        // Each store's views are computed once per check, not once per citation.
        var views: [ImageSlot: StoreView] = [:]
        for (slot, store) in source.stores { views[slot] = StoreView(store) }
        for citation in citations {
            // An image that is no longer the one the citation was made against outranks everything else.
            if let slot = citation.slot, let cited = citation.generation?.imageIdentity,
               let current = source.imageIdentities[slot], current != cited {
                result.stale.append(citation); result.causes[citation] = .imageChanged
                continue
            }
            let slots = citation.slot.map { [$0] } ?? source.slots
            var outcome = Classification.absent
            var foundIn: ImageSlot?
            for slot in slots {
                guard let view = views[slot] else { continue }
                let found = classify(citation, in: view)
                if case .absent = found { continue }
                outcome = found; foundIn = slot
                break
            }
            switch outcome {
            case .absent:
                result.unsupported.append(citation)
            case .stale(let cause):
                result.stale.append(citation); result.causes[citation] = cause
            case .live(let fact):
                if citation.slot == nil, let slot = foundIn, let cited = citation.generation?.imageIdentity,
                   let current = source.imageIdentities[slot], current != cited {
                    result.stale.append(citation); result.causes[citation] = .imageChanged
                } else {
                    result.supported.append(citation)
                    if let fact { liveFacts.append((citation, fact)) }
                }
            }
        }
        let conflicting = conflictingCitations(liveFacts)
        if !conflicting.isEmpty {
            result.conflicting = conflicting
            result.supported.removeAll { conflicting.contains($0) }
        }
        return result
    }

    /// Every finding without a stale mark whose citations the given slots no longer support.
    /// A retracted finding keeps its displayed standing, but records a latent stale mark so
    /// undoing its retraction cannot silently restore unsupported evidence.
    /// `slots == nil` considers every finding.
    static func staleMarks(in records: [AnalystFindingRecord], touching slots: Set<ImageSlot>?,
                           source: AnalystFindingSupportSource) -> [AnalystFindingStaleMark] {
        var marks: [AnalystFindingStaleMark] = []
        for record in records {
            guard record.authoredLifecycle.state.staleReason == nil else { continue }
            let citations = record.citations
            guard !citations.isEmpty else { continue }
            if let slots, !citations.contains(where: { citation in citation.slot.map(slots.contains) ?? true }) { continue }
            // A slot whose navigator state is not installed (a document still opening) says nothing about its
            // citations, so they are not judged; only a changed image identity still counts against them.
            let judged = citations.filter { citation in
                guard let slot = citation.slot else { return !source.stores.isEmpty }
                if source.stores[slot] != nil { return true }
                guard let cited = citation.generation?.imageIdentity, let now = source.imageIdentities[slot] else { return false }
                return cited != now
            }
            if let reason = check(judged, source: source).staleReason {
                marks.append(.init(findingID: record.id, reason: reason))
            }
        }
        return marks
    }

    /// Every finding without a stale mark citing another identity of the image in `slot`.
    /// Used when a slot's image is replaced or reopened with a different identity: the cited facts
    /// may not even exist any more, so this does not read the store.
    static func imageChangeMarks(in records: [AnalystFindingRecord], slot: ImageSlot,
                                 currentIdentity: String) -> [AnalystFindingStaleMark] {
        records.compactMap { record in
            guard record.authoredLifecycle.state.staleReason == nil, record.citations.contains(where: {
                $0.slot == slot && ($0.generation.map { $0.imageIdentity != currentIdentity } ?? false)
            }) else { return nil }
            return .init(findingID: record.id, reason: .imageChanged)
        }
    }

    // MARK: - classification

    private enum Classification {
        case absent
        case stale(AnalystFindingStaleReason)
        /// `nil` for an annotation, which has no subject or predicate to conflict on.
        case live(NavigatorFact?)
    }

    /// The three views of one contract store a check reads.
    private struct StoreView {
        let facts: [String: NavigatorFact]
        let live: [String: NavigatorFact]
        let annotations: [String: NavigatorAnnotation]
        init(_ store: NavigatorContractStore) {
            facts = store.allFacts(); live = store.liveFacts(); annotations = store.annotations()
        }
    }

    private static func classify(_ citation: FactCitation, in view: StoreView) -> Classification {
        let facts = view.facts
        if let fact = facts[citation.id] {
            guard let live = view.live[citation.id] else {
                return .stale(premiseCause(of: fact, facts: facts, annotations: view.annotations) ?? .factStale)
            }
            if let cited = citation.generation, let now = live.generation, cited != now {
                return .stale(cited.imageIdentity != now.imageIdentity ? .imageChanged : .factStale)
            }
            return .live(live)
        }
        if let annotation = annotation(for: citation.id, in: view.annotations) {
            if annotation.reverted { return .stale(.premiseReverted) }
            // An annotation whose own cited facts died no longer counts either.
            if annotation.cites.contains(where: { view.live[$0] == nil }) { return .stale(.factStale) }
            if let cited = citation.generation, let now = annotation.generation, cited != now {
                return .stale(cited.imageIdentity != now.imageIdentity ? .imageChanged : .factStale)
            }
            return .live(nil)
        }
        return .absent
    }

    /// `.premiseReverted` when a reverted annotation sits anywhere under the fact's derivations; nil when
    /// the fact lost support some other way.
    private static func premiseCause(of fact: NavigatorFact, facts: [String: NavigatorFact],
                                     annotations: [String: NavigatorAnnotation]) -> AnalystFindingStaleReason? {
        var seen = Set<String>()
        var pending = [fact]
        while let next = pending.popLast() {
            for group in next.derivedFrom ?? [] {
                for premise in group where seen.insert(premise).inserted {
                    if let parent = facts[premise] { pending.append(parent) }
                    else if let annotation = annotation(for: premise, in: annotations), annotation.reverted {
                        return .premiseReverted
                    }
                }
            }
        }
        return nil
    }

    /// Accepts both annotation id forms: the store's own `a…` id and a premise of the form
    /// `ann:<session>/<seq>`.
    private static func annotation(for id: String, in annotations: [String: NavigatorAnnotation]) -> NavigatorAnnotation? {
        if let direct = annotations[id] { return direct }
        guard id.hasPrefix("ann:") else { return nil }
        let body = id.dropFirst("ann:".count)
        guard let slash = body.lastIndex(of: "/"), let seq = Int64(body[body.index(after: slash)...]) else { return nil }
        let session = String(body[..<slash])
        return annotations.values.first { $0.session == session && $0.seq == seq }
    }

    private struct ConflictKey: Hashable {
        let subject: NavigatorSubject
        let predicate: String
    }

    /// Citations whose live facts assert different values for one single-valued predicate of one subject.
    private static func conflictingCitations(_ cited: [(citation: FactCitation, fact: NavigatorFact)]) -> [FactCitation] {
        var groups: [ConflictKey: [(citation: FactCitation, value: String)]] = [:]
        for entry in cited where NavigatorContractVocabulary.predicates[entry.fact.predicate]?.multi != true {
            let value = (try? NavigatorJSONCanonical.encode(entry.fact.value)) ?? ""
            groups[ConflictKey(subject: entry.fact.subject, predicate: entry.fact.predicate), default: []]
                .append((entry.citation, value))
        }
        var flagged = Set<FactCitation>()
        for members in groups.values where Set(members.map(\.value)).count > 1 {
            for member in members { flagged.insert(member.citation) }
        }
        return cited.map(\.citation).filter(flagged.contains)
    }
}

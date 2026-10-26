import Foundation

/// The reversible view of contract v1 (README §5): base facts plus an append-only journal. Every
/// view (live facts, displayed values, frontier) is a pure function of the two, so undoing a
/// session drops its journal entries and restores the exact prior state. Port of
/// `contract.Store`; the Linux differential harness replays the same sessions through both.
///
/// Revision 1.1: the journal is bounded (`journalLimit`); appending past the bound folds the oldest
/// entry into the base without changing any view, and its session can no longer be undone. Equal
/// facts union their provenance. A derivation premise may name an accepted annotation
/// (`ann:<session>/<seq>`). Facts a reanalysis invalidated are marked stale (`staleGeneration`) and
/// are not live. Competing single values of live facts are raised as `conflictingFacts`.
struct NavigatorContractStore: Sendable {
    enum Operation: Hashable, Sendable {
        case result(NavigatorPrimitiveResult)
        case accept(NavigatorAnnotation)
        case revert(target: String)
    }

    /// What the engine shows for (subject, predicate). `source` is one of `precedence`; `values`
    /// holds canonical JSON, sorted by scalars; `conflict` marks competing single values.
    struct Displayed: Hashable, Sendable {
        var source: String
        var values: [String]
        var support: [String]
        var conflict = false
    }

    /// The observable effect a revert would have: computed by applying the real `revert` to a copy
    /// (the store is a value type), so it can never disagree with the revert itself.
    struct RevertPreview: Hashable, Sendable {
        /// Live fact ids that stop being live (the target and everything resting on it).
        var factsLost: [String]
        /// Live annotation ids that stop being live (reverted or newly stale).
        var annotationsAffected: [String]
        /// Frontier item ids the revert raises (stale annotations, unblocked conflicts).
        var frontierRaised: [String]
        /// Set when the revert would be refused; the three lists are then empty.
        var refusal: NavigatorRefusal?
    }

    /// Highest first. `proven` sits directly below the analyst (README §5).
    static let precedence = ["authoritative", "analyst", "proven", "navigator", "derived", "candidate", "fallback"]
    /// Journal entries kept reversible (`contract.JOURNAL_LIMIT`).
    static let journalBound = 1024
    /// Statuses whose competing single values are raised as `conflictingFacts`.
    static let conflictStatuses = ["authoritative", "proven", "derived"]

    var toolchain: String
    var baseFacts: [NavigatorFact]
    var baseFrontier: [NavigatorFrontierItem]
    /// Accepted annotations folded out of the journal by the bound.
    private(set) var baseAnnotations: [NavigatorAnnotation] = []
    /// Revert targets folded out of the journal by the bound.
    private(set) var baseReverted: [String] = []
    private(set) var journal: [(session: String, operation: Operation)] = []
    /// How many entries the journal may hold before the oldest folds into the base.
    let journalLimit: Int
    /// How many journal entries were folded into the base; nil until the bound is first reached.
    private(set) var evictedBefore: Int?
    /// Sessions with at least one folded entry (exact scalars); `undoSession` refuses them.
    private var foldedSessions: Set<[UInt8]> = []
    /// Fact ids a reanalysis invalidated (generation fencing). Not live until a producer re-asserts them.
    private(set) var staleGeneration: Set<String> = []

    init(toolchain: String, baseFacts: [NavigatorFact] = [], baseFrontier: [NavigatorFrontierItem] = [],
         journalLimit: Int = NavigatorContractStore.journalBound) {
        self.toolchain = toolchain
        self.baseFacts = baseFacts
        self.baseFrontier = baseFrontier
        self.journalLimit = max(1, journalLimit)
    }

    private static func canonical(_ value: NavigatorJSONValue) -> String { (try? NavigatorJSONCanonical.encode(value)) ?? "" }
    /// Canonical bytes: the exact-comparison key. `String ==`, `Set<String>` and dictionary keys use
    /// canonical equivalence (NFC "é" == NFD "e\u{301}"); the contract compares exact scalars.
    private static func key(_ value: NavigatorJSONValue) -> [UInt8] { Array(canonical(value).utf8) }
    private static func sameScalars(_ a: String, _ b: String) -> Bool { a.unicodeScalars.elementsEqual(b.unicodeScalars) }

    /// Two records with one id are one fact: keep the first record, union the provenance entries
    /// (exact canonical bytes, first-seen order) and take the newer generation stamp when present.
    /// The first rule-bearing entry stays first, so the id (which digests the rule key) is unchanged.
    static func merge(_ existing: NavigatorFact, _ incoming: NavigatorFact) -> NavigatorFact {
        var merged = existing
        var seen = Set(existing.provenance.map { key($0.json) })
        for entry in incoming.provenance where seen.insert(key(entry.json)).inserted {
            merged.provenance.append(entry)
        }
        if let generation = incoming.generation { merged.generation = generation }
        if let dependsOn = incoming.dependsOn { merged.dependsOn = dependsOn }
        return merged
    }

    // MARK: - journal

    private mutating func append(_ session: String, _ operation: Operation) {
        journal.append((session, operation))
        while journal.count > journalLimit {
            let oldest = journal.removeFirst()
            fold(oldest.operation)
            foldedSessions.insert(Array(oldest.session.utf8))
            evictedBefore = (evictedBefore ?? 0) + 1
        }
    }

    /// Moves one journal entry into the base. Every view is unchanged: the entry was the oldest, so
    /// the base already precedes it in every fold the views perform.
    private mutating func fold(_ operation: Operation) {
        switch operation {
        case .result(let result):
            for fact in result.facts {
                if let index = baseFacts.lastIndex(where: { $0.id == fact.id }) {
                    baseFacts[index] = Self.merge(baseFacts[index], fact)
                } else {
                    baseFacts.append(fact)
                }
            }
            for item in result.frontier where !baseFrontier.contains(where: { $0.id == item.id }) {
                baseFrontier.append(item)
            }
        case .accept(let annotation):
            baseAnnotations.append(annotation)
        case .revert(let target):
            baseReverted.append(target)
        }
    }

    /// False once an entry of `session` was folded into the base.
    func isUndoable(_ session: String) -> Bool { !foldedSessions.contains(Array(session.utf8)) }

    // MARK: - operations (nil on success, else the refusal)

    mutating func add(_ result: NavigatorPrimitiveResult, session: String) -> NavigatorRefusal? {
        let problems = NavigatorContractValidator.validateResult(result.json)
        if let first = problems.first { return NavigatorRefusal("malformedInput", first) }
        if let refusal = result.refusal { return refusal }
        let view = liveView()
        var known = view.facts
        for fact in result.facts { known[fact.id] = fact }
        for fact in result.facts {
            for group in fact.derivedFrom ?? [] {
                if let parent = group.first(where: { known[$0] == nil && !view.premises.contains(Array($0.utf8)) }) {
                    return NavigatorRefusal("unknownFact", "\(fact.id) derives from \(parent)")
                }
                if fact.status == "derived",
                   let weak = group.first(where: { premise in
                       known[premise].map { !["authoritative", "proven", "derived"].contains($0.status) } ?? false
                   }) {
                    return NavigatorRefusal("preconditionFailed", "derived \(fact.id) rests on \(known[weak]!.status) \(weak)")
                }
            }
        }
        var prospective = allFacts()
        for fact in result.facts where prospective[fact.id] == nil { prospective[fact.id] = fact }
        if NavigatorContractValidator.hasCycle(prospective) {
            return NavigatorRefusal("preconditionFailed", "result contains a derivation cycle")
        }
        append(session, .result(result))
        // A producer re-asserting a fact under the current generation clears its stale mark.
        for fact in result.facts { staleGeneration.remove(fact.id) }
        return nil
    }

    mutating func accept(_ annotation: NavigatorAnnotation) -> NavigatorRefusal? {
        let problems = NavigatorContractValidator.validateAnnotation(annotation.json)
        if let first = problems.first { return NavigatorRefusal("malformedInput", first) }
        if annotations().keys.contains(annotation.id) {
            return NavigatorRefusal("preconditionFailed", "annotation \(annotation.id) already accepted")
        }
        let live = liveFacts()
        for cited in annotation.cites where live[cited] == nil {
            return NavigatorRefusal("unknownFact", "cites \(cited), which is not a live fact")
        }
        if annotation.author == "navigator", NavigatorContractVocabulary.predicates[annotation.predicate]?.multi != true {
            let value = Self.key(annotation.value)
            let subject = Self.key(annotation.subject.json)
            for fact in live.values.sorted(by: { $0.id < $1.id })
            where Self.key(fact.subject.json) == subject && Self.sameScalars(fact.predicate, annotation.predicate)
                && (fact.status == "authoritative" || fact.status == "proven") && Self.key(fact.value) != value {
                return NavigatorRefusal("conflictsWithAuthority", "\(fact.status) \(fact.id) holds a different value")
            }
        }
        append(annotation.session, .accept(annotation))
        return nil
    }

    mutating func revert(_ handle: String, session: String) -> NavigatorRefusal? {
        let target = handle.hasPrefix("revert:") ? String(handle.dropFirst("revert:".count)) : ""
        if NavigatorContractValidator.isFactID(target) {
            guard let fact = allFacts()[target], liveFacts()[target] != nil else {
                return NavigatorRefusal("unknownFact", "\(target) is not live")
            }
            if fact.status == "authoritative" {
                return NavigatorRefusal("notReversible", "authoritative facts are read from the image")
            }
        } else if NavigatorContractValidator.isAnnotationID(target) {
            guard let annotation = annotations()[target], !annotation.reverted else {
                return NavigatorRefusal("unknownFact", "\(target) is not a live annotation")
            }
        } else {
            return NavigatorRefusal("malformedInput", "bad revert handle")
        }
        append(session, .revert(target: target))
        return nil
    }

    /// Drops every journal entry of `session`; returns how many were removed, or `notReversible`
    /// when an entry of the session was already folded into the base by the journal bound.
    @discardableResult
    mutating func undoSession(_ session: String) -> Result<Int, NavigatorRefusal> {
        guard isUndoable(session) else {
            return .failure(NavigatorRefusal("notReversible", "journal evicted before session \(session)"))
        }
        let before = journal.count
        journal.removeAll { Self.sameScalars($0.session, session) }
        return .success(before - journal.count)
    }

    /// Marks known facts stale; returns the newly marked ids, sorted.
    @discardableResult
    mutating func markStale(_ ids: [String]) -> [String] {
        let facts = allFacts()
        let fresh = ids.filter { facts[$0] != nil && !staleGeneration.contains($0) }.uniqueSortedByScalars()
        staleGeneration.formUnion(fresh)
        return fresh
    }

    /// Generation fence: every live fact whose `dependsOn` meets a changed fingerprint facet goes
    /// stale; annotations citing them become stale (and raise `staleAnnotation`) as a consequence.
    @discardableResult
    mutating func markStaleGeneration(changedFacets: Set<String>) -> [String] {
        markStale(liveFacts().values.filter { fact in
            (fact.dependsOn ?? []).contains(where: changedFacets.contains)
        }.map(\.id))
    }

    /// What `revert(handle, session:)` would change, computed on a copy; `self` is untouched.
    func preview(revert handle: String, session: String = "preview") -> RevertPreview {
        var trial = self
        let beforeFacts = Array(liveFacts().keys)
        let beforeAnnotations = liveAnnotations().map(\.id)
        let beforeFrontier = Set(frontier().map(\.id))
        if let refusal = trial.revert(handle, session: session) {
            return RevertPreview(factsLost: [], annotationsAffected: [], frontierRaised: [], refusal: refusal)
        }
        let afterFacts = trial.liveFacts()
        let afterAnnotations = Set(trial.liveAnnotations().map(\.id))
        return RevertPreview(
            factsLost: beforeFacts.filter { afterFacts[$0] == nil }.uniqueSortedByScalars(),
            annotationsAffected: beforeAnnotations.filter { !afterAnnotations.contains($0) }.uniqueSortedByScalars(),
            frontierRaised: trial.frontier().map(\.id).filter { !beforeFrontier.contains($0) }.uniqueSortedByScalars(),
            refusal: nil)
    }

    // MARK: - views

    func allFacts() -> [String: NavigatorFact] {
        var facts: [String: NavigatorFact] = [:]
        for fact in baseFacts { facts[fact.id] = fact }
        for entry in journal {
            if case .result(let result) = entry.operation {
                for fact in result.facts {
                    if let existing = facts[fact.id] { facts[fact.id] = Self.merge(existing, fact) } else { facts[fact.id] = fact }
                }
            }
        }
        return facts
    }

    func revertedTargets() -> Set<String> {
        var targets = Set(baseReverted)
        for entry in journal {
            if case .revert(let target) = entry.operation { targets.insert(target) }
        }
        return targets
    }

    /// Live facts and live annotation premises, to a joint fixed point. A fact is live when it is
    /// neither reverted nor stale and, if derived, one of its derivations (a conjunction of premises:
    /// fact ids or `ann:<session>/<seq>`) fully survives; an annotation premise is live when an
    /// unreverted annotation with that session and seq cites only live facts.
    private func liveView() -> (facts: [String: NavigatorFact], premises: Set<[UInt8]>) {
        let reverted = revertedTargets()
        let open = annotations().values.filter { !$0.reverted }
        var live = allFacts().filter { !reverted.contains($0.key) && !staleGeneration.contains($0.key) }
        while true {
            let premises = Set(open.filter { $0.cites.allSatisfy { live[$0] != nil } }.map { Array($0.premise.utf8) })
            var changed = false
            for (id, fact) in live {
                if let groups = fact.derivedFrom, !groups.isEmpty,
                   !groups.contains(where: { $0.allSatisfy { live[$0] != nil || premises.contains(Array($0.utf8)) } }) {
                    live[id] = nil
                    changed = true
                }
            }
            if !changed { return (live, premises) }
        }
    }

    /// Facts minus reverted and stale ones and, to a fixed point, every fact none of whose
    /// derivations (each a conjunction of premises) survives.
    func liveFacts() -> [String: NavigatorFact] { liveView().facts }

    /// `ann:<session>/<seq>` handles a derivation can currently rest on.
    func livePremises() -> [String] {
        let live = liveFacts()
        return annotations().values.filter { !$0.reverted && $0.cites.allSatisfy { live[$0] != nil } }
            .map(\.premise).uniqueSortedByScalars()
    }

    func annotations() -> [String: NavigatorAnnotation] {
        let reverted = revertedTargets()
        var result: [String: NavigatorAnnotation] = [:]
        for var annotation in baseAnnotations {
            annotation.reverted = reverted.contains(annotation.id)
            result[annotation.id] = annotation
        }
        for entry in journal {
            if case .accept(var annotation) = entry.operation {
                annotation.reverted = reverted.contains(annotation.id)
                result[annotation.id] = annotation
            }
        }
        return result
    }

    func liveAnnotations() -> [NavigatorAnnotation] {
        let live = liveFacts()
        return annotations().values.filter { !$0.reverted && $0.cites.allSatisfy { live[$0] != nil } }.sorted { $0.id < $1.id }
    }

    func staleAnnotations() -> [NavigatorAnnotation] {
        let live = liveFacts()
        return annotations().values.filter { !$0.reverted && !$0.cites.allSatisfy { live[$0] != nil } }.sorted { $0.id < $1.id }
    }

    func display(_ subject: NavigatorSubject, _ predicate: String) -> Displayed {
        let multi = NavigatorContractVocabulary.predicates[predicate]?.multi == true
        let key = Self.key(subject.json)
        let facts = liveFacts().values.filter { Self.key($0.subject.json) == key && Self.sameScalars($0.predicate, predicate) }
        let notes = liveAnnotations().filter { Self.key($0.subject.json) == key && Self.sameScalars($0.predicate, predicate) }

        func pick(_ source: String, _ items: [(value: String, id: String)]) -> Displayed? {
            guard !items.isEmpty else { return nil }
            let values = items.map(\.value).uniqueSortedByScalars()
            let support = items.map(\.id).uniqueSortedByScalars()
            return Displayed(source: source, values: values, support: support, conflict: !multi && values.count > 1)
        }

        if let shown = pick("authoritative", facts.filter { $0.status == "authoritative" }.map { (Self.canonical($0.value), $0.id) }) {
            return shown
        }
        let analyst = notes.filter { $0.author == "analyst" }.sorted { ($0.seq, $0.id) < ($1.seq, $1.id) }
        if let latest = analyst.last {
            if multi { return pick("analyst", analyst.map { (Self.canonical($0.value), $0.id) })! }
            return Displayed(source: "analyst", values: [Self.canonical(latest.value)], support: [latest.id])
        }
        if let shown = pick("proven", facts.filter { $0.status == "proven" }.map { (Self.canonical($0.value), $0.id) }) {
            return shown
        }
        if let shown = pick("navigator", notes.filter { $0.author == "navigator" }.map { (Self.canonical($0.value), $0.id) }) {
            return shown
        }
        let derived = facts.filter { $0.status == "derived" }
        if let best = derived.compactMap(\.tier).max(),
           let shown = pick("derived", derived.filter { $0.tier == best }.map { (Self.canonical($0.value), $0.id) }) {
            return shown
        }
        let candidates = facts.filter { $0.status == "candidate" }
        if !candidates.isEmpty {
            var items: [(value: String, id: String)] = []
            for fact in candidates {
                for alternative in fact.value["alternatives"]?.arrayValue ?? [] { items.append((Self.canonical(alternative), fact.id)) }
            }
            return Displayed(source: "candidate", values: items.map(\.value).uniqueSortedByScalars(),
                             support: items.map(\.id).uniqueSortedByScalars(), conflict: true)
        }
        return Displayed(source: "fallback", values: [], support: [])
    }

    /// Base and result frontier items whose blockers are live, plus the items the store raises
    /// itself: conflicting live facts, conflicting navigator annotations and stale annotations;
    /// sorted by id.
    func frontier() -> [NavigatorFrontierItem] {
        let live = liveFacts()
        var items: [String: NavigatorFrontierItem] = [:]
        for item in baseFrontier { items[item.id] = item }
        for entry in journal {
            if case .result(let result) = entry.operation {
                for item in result.frontier where items[item.id] == nil { items[item.id] = item }
            }
        }
        var result = items.values.filter { $0.blockedBy.allSatisfy { live[$0] != nil } }
        var factGroups: [[UInt8]: [NavigatorFact]] = [:]
        for fact in live.values
        where Self.conflictStatuses.contains(fact.status) && NavigatorContractVocabulary.predicates[fact.predicate]?.multi != true {
            factGroups[Self.key(.array([fact.subject.json, .string(fact.predicate)])), default: []].append(fact)
        }
        for key in factGroups.keys.sorted(by: { $0.lexicographicallyPrecedes($1) }) {
            let facts = factGroups[key]!.sorted { $0.id < $1.id }
            let values = facts.map { Self.canonical($0.value) }.uniqueSortedByScalars()
            guard values.count > 1 else { continue }
            if let item = try? NavigatorFrontierItem.make(
                subject: facts[0].subject, gap: "conflictingFacts",
                detail: "\(facts[0].predicate): \(values.joined(separator: " | "))", toolchain: toolchain,
                blockedBy: facts.map(\.id),
                primitives: [NavigatorPrimitiveRef(name: "revert", preconditions: ["analyst decision"])]),
               items[item.id] == nil {
                result.append(item)
            }
        }
        var groups: [[UInt8]: [NavigatorAnnotation]] = [:]
        for annotation in liveAnnotations()
        where annotation.author == "navigator" && NavigatorContractVocabulary.predicates[annotation.predicate]?.multi != true {
            groups[Self.key(.array([annotation.subject.json, .string(annotation.predicate)])), default: []].append(annotation)
        }
        for key in groups.keys.sorted(by: { $0.lexicographicallyPrecedes($1) }) {
            let notes = groups[key]!
            let values = notes.map { Self.canonical($0.value) }.uniqueSortedByScalars()
            guard values.count > 1 else { continue }
            let cited = notes.flatMap(\.cites).uniqueSortedByScalars()
            if let item = try? NavigatorFrontierItem.make(
                subject: notes[0].subject, gap: "conflictingAnnotations",
                detail: "\(notes[0].predicate): \(values.joined(separator: " | "))", toolchain: toolchain, blockedBy: cited,
                primitives: [NavigatorPrimitiveRef(name: "acceptAnnotation", preconditions: ["analyst decision"])]),
               items[item.id] == nil {
                result.append(item)
            }
        }
        for annotation in staleAnnotations() {
            if let item = try? NavigatorFrontierItem.make(subject: annotation.subject, gap: "staleAnnotation",
                                                          detail: "\(annotation.id) cites a reverted fact", toolchain: toolchain),
               items[item.id] == nil {
                result.append(item)
            }
        }
        return result.sorted { $0.id < $1.id }
    }

    // MARK: - persistence

    /// Persistable snapshot: every fact, the reverted fact ids, the frontier and every accepted
    /// annotation with its reverted flag. Stale marks are not part of the v1 record; the workspace
    /// envelope carries them beside it.
    func state() -> NavigatorEngineState {
        let facts = allFacts()
        return NavigatorEngineState(
            toolchain: toolchain, facts: facts.values.sorted { $0.id < $1.id },
            reverted: revertedTargets().filter { facts[$0] != nil }, frontier: frontier(),
            annotations: annotations().values.sorted { ($0.seq, $0.id) < ($1.seq, $1.id) })
    }

    /// Inverse of `state()` for the observable view (journal history is not persisted). The
    /// annotations and reverts are replayed and `staleGeneration` (the stale marks the workspace
    /// envelope carries beside the v1 record) is applied first; the persisted frontier items the
    /// store then regenerates itself are dropped, so a re-derived item is never duplicated and an
    /// item whose cause no longer holds leaves nothing behind. The remaining persisted items stay
    /// as supplied, byte for byte.
    init(state: NavigatorEngineState, session: String = "restored", staleGeneration: [String] = [],
         journalLimit: Int = NavigatorContractStore.journalBound) {
        self.init(toolchain: state.toolchain, baseFacts: state.facts, journalLimit: journalLimit)
        for annotation in state.annotations.sorted(by: { ($0.seq, $0.id) < ($1.seq, $1.id) }) {
            var accepted = annotation
            accepted.reverted = false
            append(annotation.session, .accept(accepted))
        }
        for target in state.reverted { append(session, .revert(target: target)) }
        for annotation in state.annotations where annotation.reverted { append(session, .revert(target: annotation.id)) }
        markStale(staleGeneration)
        let regenerated = Set(frontier().map { Self.key($0.json) })
        baseFrontier = state.frontier.filter { !regenerated.contains(Self.key($0.json)) }
    }

    /// Everything a client can observe for `keys`, canonically encoded (compared across languages).
    func snapshot(_ keys: [(NavigatorSubject, String)]) -> String {
        let view: NavigatorJSONValue = .object([
            "facts": .array(Array(liveFacts().keys).uniqueSortedByScalars().map { .string($0) }),
            "frontier": .array(frontier().map { .string($0.id) }),
            "annotations": .array(liveAnnotations().map(\.id).uniqueSortedByScalars().map { .string($0) }),
            "display": .array(keys.map { subject, predicate in
                let shown = display(subject, predicate)
                return .array([.string(Self.canonical(subject.json)), .string(predicate),
                               .array(shown.values.map { .string($0) }), .string(shown.source)])
            }),
        ])
        return Self.canonical(view)
    }
}

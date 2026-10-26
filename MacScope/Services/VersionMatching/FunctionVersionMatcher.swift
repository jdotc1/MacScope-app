import Foundation

/// Pure, deterministic cross-version function matcher (roadmap M8, binary-version matching).
///
/// This pairs functions of two versions of the same binary. It is a different operation from
/// comparing two providers' output for one function, and shares no state with that path.
///
/// Correctness over coverage: every automatic phase accepts only pairs that are unique on BOTH
/// sides among still-unmatched functions. Anything else is reported as an unresolved group and is
/// never guessed. Phases run highest-confidence first and the whole pipeline repeats to a fixpoint,
/// restarting from the strongest phase whenever any phase accepts a pair:
///
/// 1. manual pins (validated, applied before any automatic evidence);
/// 2. identical non-generated symbol name;
/// 3. identical masked instruction-stream digest;
/// 4. identical CFG shape digest plus identical named-callee set (informative keys only);
/// 5. call-graph propagation: under a matched caller pair, an unmatched callee pair that is the
///    unique structurally compatible candidate in both directions, consistently across all callers.
///
/// Output depends only on the multiset of fingerprints and pins, never on input order.
struct FunctionVersionMatcher: Sendable {
    /// Inputs in canonical (address, id) order.
    let oldFunctions: [FunctionVersionFingerprint]
    let newFunctions: [FunctionVersionFingerprint]
    private let oldByID: [String: FunctionVersionFingerprint]
    private let newByID: [String: FunctionVersionFingerprint]

    init(old: [FunctionVersionFingerprint], new: [FunctionVersionFingerprint]) throws {
        oldFunctions = old.sorted(by: Self.canonicalOrder)
        newFunctions = new.sorted(by: Self.canonicalOrder)
        var oldByID: [String: FunctionVersionFingerprint] = [:]
        for function in oldFunctions {
            guard oldByID.updateValue(function, forKey: function.id) == nil else {
                throw FunctionVersionMatcherError.duplicateOldID(function.id)
            }
        }
        var newByID: [String: FunctionVersionFingerprint] = [:]
        for function in newFunctions {
            guard newByID.updateValue(function, forKey: function.id) == nil else {
                throw FunctionVersionMatcherError.duplicateNewID(function.id)
            }
        }
        self.oldByID = oldByID
        self.newByID = newByID
    }

    // MARK: - Public operations

    /// Matches the two versions, honoring `pins` before any automatic evidence.
    func match(pins: [FunctionVersionManualPin] = []) throws -> FunctionVersionMatchResult {
        let canonicalPins = try validatedPins(pins)
        var state = MatchState()
        for pin in canonicalPins {
            state.accept(old: pin.oldID, new: pin.newID, Acceptance(basis: .manual, confidence: .userConfirmed))
        }
        while true {
            if applyUniqueKeyPhase(&state, basis: .symbolName, oldKey: { Self.nameKey($0) }, newKey: { Self.nameKey($0) }) { continue }
            if applyUniqueKeyPhase(&state, basis: .normalizedBody, oldKey: { Self.bodyKey($0) }, newKey: { Self.bodyKey($0) }) { continue }
            if applyUniqueKeyPhase(&state, basis: .controlFlowAndCallees,
                                   oldKey: { Self.controlFlowCalleeKey($0, siblings: oldByID) },
                                   newKey: { Self.controlFlowCalleeKey($0, siblings: newByID) }) { continue }
            if applyPropagation(&state) { continue }
            break
        }
        return buildResult(state, pins: canonicalPins)
    }

    /// Refines `result` with one user-pinned pair and recomputes every automatic phase from
    /// scratch with the accumulated pins, so the outcome is a pure function of (inputs, pins).
    /// Both functions must exist and must be unmatched in `result`.
    func resolve(_ result: FunctionVersionMatchResult, pinning pin: FunctionVersionManualPin) throws -> FunctionVersionMatchResult {
        guard oldByID[pin.oldID] != nil else { throw FunctionVersionMatcherError.unknownOldID(pin.oldID) }
        guard newByID[pin.newID] != nil else { throw FunctionVersionMatcherError.unknownNewID(pin.newID) }
        guard result.match(forOldID: pin.oldID) == nil else { throw FunctionVersionMatcherError.oldAlreadyMatched(pin.oldID) }
        guard result.match(forNewID: pin.newID) == nil else { throw FunctionVersionMatcherError.newAlreadyMatched(pin.newID) }
        return try match(pins: result.manualPins + [pin])
    }

    // MARK: - Pins

    private func validatedPins(_ pins: [FunctionVersionManualPin]) throws -> [FunctionVersionManualPin] {
        let unique = Array(Set(pins))
        for pin in unique {
            guard oldByID[pin.oldID] != nil else { throw FunctionVersionMatcherError.unknownOldID(pin.oldID) }
            guard newByID[pin.newID] != nil else { throw FunctionVersionMatcherError.unknownNewID(pin.newID) }
        }
        let sorted = unique.sorted { lhs, rhs in
            Self.canonicalOrder(oldByID[lhs.oldID]!, oldByID[rhs.oldID]!)
                || (lhs.oldID == rhs.oldID && Self.canonicalOrder(newByID[lhs.newID]!, newByID[rhs.newID]!))
        }
        var byOld: [String: FunctionVersionManualPin] = [:]
        var byNew: [String: FunctionVersionManualPin] = [:]
        for pin in sorted {
            if let other = byOld[pin.oldID] { throw FunctionVersionMatcherError.conflictingPins(other, pin) }
            if let other = byNew[pin.newID] { throw FunctionVersionMatcherError.conflictingPins(other, pin) }
            byOld[pin.oldID] = pin
            byNew[pin.newID] = pin
        }
        return sorted
    }

    // MARK: - Unique-key phases

    /// Accepts every key that has exactly one unmatched function on each side. Acceptances are
    /// computed from one snapshot and applied together, so phase order within a pass is irrelevant.
    private func applyUniqueKeyPhase(
        _ state: inout MatchState,
        basis: FunctionVersionMatchBasis,
        oldKey: (FunctionVersionFingerprint) -> String?,
        newKey: (FunctionVersionFingerprint) -> String?
    ) -> Bool {
        let oldGroups = groupUnmatched(oldFunctions, matched: state.oldToNew, key: oldKey)
        let newGroups = groupUnmatched(newFunctions, matched: state.newToOld, key: newKey)
        var accepted = false
        for key in oldGroups.keys.sorted() {
            guard let olds = oldGroups[key], olds.count == 1,
                  let news = newGroups[key], news.count == 1 else { continue }
            state.accept(old: olds[0].id, new: news[0].id,
                         Acceptance(basis: basis, confidence: confidence(for: basis, old: olds[0], new: news[0])))
            accepted = true
        }
        return accepted
    }

    private func confidence(
        for basis: FunctionVersionMatchBasis,
        old: FunctionVersionFingerprint,
        new: FunctionVersionFingerprint
    ) -> FunctionVersionMatchConfidence {
        switch basis {
        case .manual: return .userConfirmed
        case .symbolName: return .high
        case .normalizedBody:
            // A unique two-instruction stub is weaker evidence than a unique substantial body.
            let count = min(old.instructionCount ?? 0, new.instructionCount ?? 0)
            return count >= Self.substantialBodyInstructionCount ? .high : .medium
        case .controlFlowAndCallees: return .medium
        case .callGraphPropagation: return .low
        }
    }

    static let substantialBodyInstructionCount = 3

    private func groupUnmatched(
        _ functions: [FunctionVersionFingerprint],
        matched: [String: String],
        key: (FunctionVersionFingerprint) -> String?
    ) -> [String: [FunctionVersionFingerprint]] {
        var groups: [String: [FunctionVersionFingerprint]] = [:]
        for function in functions where matched[function.id] == nil {
            guard let value = key(function) else { continue }
            groups[value, default: []].append(function)   // functions are canonical, so groups are too
        }
        return groups
    }

    static func nameKey(_ function: FunctionVersionFingerprint) -> String? {
        guard let name = function.symbolName, !FunctionVersionFingerprinting.isGeneratedName(name) else { return nil }
        return name
    }

    static func bodyKey(_ function: FunctionVersionFingerprint) -> String? {
        function.normalizedBodyHash
    }

    /// CFG shape + the names of everything the function calls. Returns nil (no evidence) when any
    /// input is unknown, or when the key is uninformative: a single-block function with no named
    /// callee carries too little structure to identify anything.
    static func controlFlowCalleeKey(
        _ function: FunctionVersionFingerprint,
        siblings: [String: FunctionVersionFingerprint]
    ) -> String? {
        guard let shape = function.cfgShapeHash,
              let calleeIDs = function.calleeIDs,
              let imported = function.importedCalleeNames else { return nil }
        var names = imported.map { "import:" + $0 }
        var unnamedCount = 0
        for id in calleeIDs {
            if let callee = siblings[id], let name = nameKey(callee) {
                names.append("local:" + name)
            } else {
                unnamedCount += 1
            }
        }
        let namedCallees = names.sorted()
        guard (function.basicBlockCount ?? 0) >= 2 || !namedCallees.isEmpty else { return nil }
        return ([shape, String(unnamedCount)] + namedCallees).joined(separator: "\u{1F}")
    }

    // MARK: - Call-graph propagation

    private struct PropagationRound {
        /// (old, new) → first caller pair (canonical caller order) that proposed it.
        var proposals: [Pair: Pair] = [:]
        var proposedNews: [String: Set<String>] = [:]
        var proposedOlds: [String: Set<String>] = [:]
        /// Compatible pairs that some caller context could not disambiguate.
        var ambiguous: Set<Pair> = []
    }

    private func propagationRound(_ state: MatchState) -> PropagationRound {
        var round = PropagationRound()
        for oldCaller in oldFunctions {
            guard let newCallerID = state.oldToNew[oldCaller.id], let newCaller = newByID[newCallerID] else { continue }
            let oldCandidates = unmatchedCallees(of: oldCaller, in: oldByID, matched: state.oldToNew)
            let newCandidates = unmatchedCallees(of: newCaller, in: newByID, matched: state.newToOld)
            guard !oldCandidates.isEmpty, !newCandidates.isEmpty else { continue }
            var compatibleNews: [String: [String]] = [:]
            var compatibleOlds: [String: [String]] = [:]
            for old in oldCandidates {
                for new in newCandidates where Self.isStructurallyCompatible(old, new) {
                    compatibleNews[old.id, default: []].append(new.id)
                    compatibleOlds[new.id, default: []].append(old.id)
                }
            }
            for old in oldCandidates {
                for newID in compatibleNews[old.id] ?? [] {
                    let pair = Pair(old: old.id, new: newID)
                    if compatibleNews[old.id]?.count == 1, compatibleOlds[newID]?.count == 1 {
                        if round.proposals[pair] == nil {
                            round.proposals[pair] = Pair(old: oldCaller.id, new: newCallerID)
                        }
                        round.proposedNews[old.id, default: []].insert(newID)
                        round.proposedOlds[newID, default: []].insert(old.id)
                    } else {
                        round.ambiguous.insert(pair)
                    }
                }
            }
        }
        return round
    }

    private func applyPropagation(_ state: inout MatchState) -> Bool {
        let round = propagationRound(state)
        var accepted = false
        for pair in round.proposals.keys.sorted(by: pairOrder) {
            // Every caller context must agree on the same partner in both directions.
            guard !round.ambiguous.contains(pair),
                  round.proposedNews[pair.old] == [pair.new], round.proposedOlds[pair.new] == [pair.old],
                  let caller = round.proposals[pair] else { continue }
            state.accept(old: pair.old, new: pair.new, Acceptance(
                basis: .callGraphPropagation, confidence: .low, callerOld: caller.old, callerNew: caller.new))
            accepted = true
        }
        return accepted
    }

    private func unmatchedCallees(
        of caller: FunctionVersionFingerprint,
        in byID: [String: FunctionVersionFingerprint],
        matched: [String: String]
    ) -> [FunctionVersionFingerprint] {
        (caller.calleeIDs ?? []).compactMap { id in matched[id] == nil ? byID[id] : nil }
            .sorted(by: Self.canonicalOrder)
    }

    /// Same CFG shape or same masked body. Unknown facts never establish compatibility.
    static func isStructurallyCompatible(_ old: FunctionVersionFingerprint, _ new: FunctionVersionFingerprint) -> Bool {
        if let shape = old.cfgShapeHash, shape == new.cfgShapeHash { return true }
        if let body = old.normalizedBodyHash, body == new.normalizedBodyHash { return true }
        return false
    }

    // MARK: - Result assembly

    private func buildResult(_ state: MatchState, pins: [FunctionVersionManualPin]) -> FunctionVersionMatchResult {
        let unresolved = unresolvedGroups(state)
        let unresolvedOld = Set(unresolved.flatMap(\.oldIDs))
        let unresolvedNew = Set(unresolved.flatMap(\.newIDs))
        var matches: [FunctionVersionMatch] = []
        for old in oldFunctions {
            guard let newID = state.oldToNew[old.id], let new = newByID[newID],
                  let acceptance = state.acceptances[old.id] else { continue }
            matches.append(FunctionVersionMatch(
                oldID: old.id, newID: new.id, oldAddress: old.address, newAddress: new.address,
                basis: acceptance.basis, confidence: acceptance.confidence,
                propagatedFromOldCallerID: acceptance.callerOld, propagatedFromNewCallerID: acceptance.callerNew,
                differences: differences(old, new, state: state, unresolvedOld: unresolvedOld, unresolvedNew: unresolvedNew),
                symbolNameChanged: old.symbolName != new.symbolName))
        }

        let removed = oldFunctions.filter { state.oldToNew[$0.id] == nil && !unresolvedOld.contains($0.id) }.map(\.id)
        let added = newFunctions.filter { state.newToOld[$0.id] == nil && !unresolvedNew.contains($0.id) }.map(\.id)
        return FunctionVersionMatchResult(
            matches: matches, addedIDs: added, removedIDs: removed, unresolved: unresolved, manualPins: pins)
    }

    private func differences(
        _ old: FunctionVersionFingerprint,
        _ new: FunctionVersionFingerprint,
        state: MatchState,
        unresolvedOld: Set<String>,
        unresolvedNew: Set<String>
    ) -> [FunctionVersionDifference] {
        var result: [FunctionVersionDifference] = []
        if Self.knownAndDifferent(old.semanticBodyHash ?? old.normalizedBodyHash,
                                  new.semanticBodyHash ?? new.normalizedBodyHash)
            || Self.knownAndDifferent(old.instructionCount, new.instructionCount) {
            result.append(.body)
        }
        if Self.knownAndDifferent(old.cfgShapeHash, new.cfgShapeHash)
            || Self.knownAndDifferent(old.basicBlockCount, new.basicBlockCount)
            || Self.knownAndDifferent(old.edgeCount, new.edgeCount) {
            result.append(.controlFlow)
        }
        if let oldCallees = old.calleeIDs, let newCallees = new.calleeIDs {
            // Compare in-image callees through the matching itself, so a callee that was merely
            // stripped or moved is not a change, while a matched-elsewhere, added or removed callee
            // is. Unresolved callees are unknown: they are excluded from the comparison, except
            // that differing callee counts prove a difference under any one-to-one pairing.
            let definiteOld = Set(oldCallees.filter { !unresolvedOld.contains($0) }
                .map { state.oldToNew[$0] ?? "\u{0}unmatched-old:" + $0 })
            let definiteNew = Set(newCallees.filter { !unresolvedNew.contains($0) })
            if oldCallees.count != newCallees.count || definiteOld != definiteNew
                || Self.knownAndDifferent(old.importedCalleeNames, new.importedCalleeNames) {
                result.append(.callees)
            }
        } else if Self.knownAndDifferent(old.importedCalleeNames, new.importedCalleeNames) {
            result.append(.callees)
        }
        if old.size != new.size { result.append(.size) }
        if Self.knownAndDifferent(old.stringReferences, new.stringReferences) { result.append(.stringReferences) }
        return result.sorted()
    }

    private static func knownAndDifferent<T: Equatable>(_ lhs: T?, _ rhs: T?) -> Bool {
        guard let lhs, let rhs else { return false }
        return lhs != rhs
    }

    /// Groups every remaining candidate relation (shared key with no one-to-one resolution, or an
    /// undecidable propagation context) into connected components.
    private func unresolvedGroups(_ state: MatchState) -> [FunctionVersionUnresolvedGroup] {
        var components = UnionFind()
        var bases: [(node: String, basis: FunctionVersionAmbiguityBasis)] = []

        func link(_ olds: [FunctionVersionFingerprint], _ news: [FunctionVersionFingerprint], _ basis: FunctionVersionAmbiguityBasis) {
            let anchor = Self.oldNode(olds[0].id)
            for old in olds { components.union(anchor, Self.oldNode(old.id)) }
            for new in news { components.union(anchor, Self.newNode(new.id)) }
            bases.append((anchor, basis))
        }
        func linkSharedKeys(
            _ basis: FunctionVersionAmbiguityBasis,
            oldKey: (FunctionVersionFingerprint) -> String?,
            newKey: (FunctionVersionFingerprint) -> String?
        ) {
            let oldGroups = groupUnmatched(oldFunctions, matched: state.oldToNew, key: oldKey)
            let newGroups = groupUnmatched(newFunctions, matched: state.newToOld, key: newKey)
            for key in oldGroups.keys.sorted() {
                guard let olds = oldGroups[key], let news = newGroups[key],
                      olds.count > 1 || news.count > 1 else { continue }
                link(olds, news, basis)
            }
        }

        linkSharedKeys(.duplicateSymbolName, oldKey: { Self.nameKey($0) }, newKey: { Self.nameKey($0) })
        linkSharedKeys(.duplicateNormalizedBody, oldKey: { Self.bodyKey($0) }, newKey: { Self.bodyKey($0) })
        linkSharedKeys(.duplicateControlFlowAndCallees,
                       oldKey: { Self.controlFlowCalleeKey($0, siblings: oldByID) },
                       newKey: { Self.controlFlowCalleeKey($0, siblings: newByID) })
        let round = propagationRound(state)
        let conflicting = round.ambiguous.union(round.proposals.keys.filter {
            round.proposedNews[$0.old] != [$0.new] || round.proposedOlds[$0.new] != [$0.old]
        })
        for pair in conflicting.sorted(by: pairOrder) {
            guard let old = oldByID[pair.old], let new = newByID[pair.new] else { continue }
            link([old], [new], .conflictingCallGraphCandidates)
        }

        var oldMembers: [String: [FunctionVersionFingerprint]] = [:]
        var newMembers: [String: [FunctionVersionFingerprint]] = [:]
        for old in oldFunctions where state.oldToNew[old.id] == nil && components.contains(Self.oldNode(old.id)) {
            oldMembers[components.find(Self.oldNode(old.id)), default: []].append(old)
        }
        for new in newFunctions where state.newToOld[new.id] == nil && components.contains(Self.newNode(new.id)) {
            newMembers[components.find(Self.newNode(new.id)), default: []].append(new)
        }
        var basesByRoot: [String: Set<FunctionVersionAmbiguityBasis>] = [:]
        for entry in bases { basesByRoot[components.find(entry.node), default: []].insert(entry.basis) }

        let groups = oldMembers.keys.compactMap { root -> (first: FunctionVersionFingerprint, group: FunctionVersionUnresolvedGroup)? in
            guard let olds = oldMembers[root], let news = newMembers[root], let first = olds.first else { return nil }
            return (first, FunctionVersionUnresolvedGroup(
                oldIDs: olds.map(\.id), newIDs: news.map(\.id), bases: (basesByRoot[root] ?? []).sorted()))
        }
        return groups.sorted { Self.canonicalOrder($0.first, $1.first) }.map(\.group)
    }

    private static func oldNode(_ id: String) -> String { "o\u{1F}" + id }
    private static func newNode(_ id: String) -> String { "n\u{1F}" + id }

    // MARK: - Ordering

    static func canonicalOrder(_ lhs: FunctionVersionFingerprint, _ rhs: FunctionVersionFingerprint) -> Bool {
        if lhs.address != rhs.address { return lhs.address < rhs.address }
        return lhs.id < rhs.id
    }

    private func pairOrder(_ lhs: Pair, _ rhs: Pair) -> Bool {
        if lhs.old != rhs.old, let l = oldByID[lhs.old], let r = oldByID[rhs.old] { return Self.canonicalOrder(l, r) }
        if lhs.new != rhs.new, let l = newByID[lhs.new], let r = newByID[rhs.new] { return Self.canonicalOrder(l, r) }
        return false
    }
}

// MARK: - Private state

private struct Pair: Hashable, Sendable {
    let old: String
    let new: String
}

private struct Acceptance: Sendable {
    let basis: FunctionVersionMatchBasis
    let confidence: FunctionVersionMatchConfidence
    var callerOld: String? = nil
    var callerNew: String? = nil
}

private struct MatchState: Sendable {
    var oldToNew: [String: String] = [:]
    var newToOld: [String: String] = [:]
    var acceptances: [String: Acceptance] = [:]

    mutating func accept(old: String, new: String, _ acceptance: Acceptance) {
        precondition(oldToNew[old] == nil && newToOld[new] == nil, "function matched twice")
        oldToNew[old] = new
        newToOld[new] = old
        acceptances[old] = acceptance
    }
}

/// Deterministic union-find over string node keys (roots chosen by lexical order).
private struct UnionFind {
    private var parent: [String: String] = [:]

    func contains(_ node: String) -> Bool { parent[node] != nil }

    mutating func find(_ node: String) -> String {
        guard let next = parent[node] else {
            parent[node] = node
            return node
        }
        if next == node { return node }
        let root = find(next)
        parent[node] = root
        return root
    }

    mutating func union(_ lhs: String, _ rhs: String) {
        let a = find(lhs)
        let b = find(rhs)
        guard a != b else { return }
        if a < b { parent[b] = a } else { parent[a] = b }
    }
}

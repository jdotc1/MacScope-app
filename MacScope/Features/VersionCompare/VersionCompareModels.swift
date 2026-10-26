import Foundation

/// One loaded workspace image that can take part in a version comparison. The exact owner
/// (`binaryID`) and analysis fingerprint are part of the identity so a replaced or re-analyzed
/// image is never confused with the image a published comparison was computed from.
struct VersionCompareImage: Identifiable, Hashable, Sendable {
    let slot: ImageSlot
    let binaryID: UUID
    let name: String
    let analysisFingerprint: String?

    var id: ImageSlot { slot }
}

/// The ordered (old → new) image pair a comparison was computed for.
struct VersionComparePair: Hashable, Sendable {
    let old: VersionCompareImage
    let new: VersionCompareImage
}

/// Display facts for one function in one image. `address` is nil only when the matcher reports an
/// id the comparison inputs cannot describe (never expected; rendered as unknown, not invented).
struct VersionCompareFunctionRef: Hashable, Sendable {
    let id: String
    let address: UInt64?
    let name: String

    var addressText: String { address?.hexAddress ?? "unknown address" }

    func matches(_ query: String) -> Bool {
        name.lowercased().contains(query) || (address?.hexAddress.contains(query) ?? false)
    }
}

enum VersionCompareStatus: String, CaseIterable, Hashable, Sendable {
    case changed, removed, added, unchanged
}

struct VersionCompareRow: Identifiable, Hashable, Sendable {
    let id: String
    let status: VersionCompareStatus
    let old: VersionCompareFunctionRef?
    let new: VersionCompareFunctionRef?
    let basis: FunctionVersionMatchBasis?
    let confidence: FunctionVersionMatchConfidence?
    let differences: [FunctionVersionDifference]
    let symbolNameChanged: Bool

    func matches(_ query: String) -> Bool {
        query.isEmpty || (old?.matches(query) ?? false) || (new?.matches(query) ?? false)
    }
}

/// One ambiguity the matcher refused to guess; its members are the manual-pin candidates.
struct VersionCompareUnresolvedGroupRow: Identifiable, Hashable, Sendable {
    let id: String
    let old: [VersionCompareFunctionRef]
    let new: [VersionCompareFunctionRef]
    let bases: [FunctionVersionAmbiguityBasis]

    func matches(_ query: String) -> Bool {
        query.isEmpty || old.contains { $0.matches(query) } || new.contains { $0.matches(query) }
    }
}

struct VersionCompareSummary: Hashable, Sendable {
    let unchanged: Int
    let changed: Int
    let added: Int
    let removed: Int
    let unresolvedGroups: Int
    let manualPins: Int
}

enum VersionCompareFilter: String, CaseIterable, Identifiable, Hashable, Sendable {
    case all, changed, added, removed, unchanged, unresolved

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All"
        case .changed: "Changed"
        case .added: "Added"
        case .removed: "Removed"
        case .unchanged: "Unchanged"
        case .unresolved: "Unresolved"
        }
    }
}

/// Pure projection of a matcher result into presentable rows. Rows are grouped by status
/// (changed, removed, added, unchanged) and keep the matcher's canonical order within a group.
struct VersionCompareReport: Hashable, Sendable {
    let rows: [VersionCompareRow]
    let unresolvedGroups: [VersionCompareUnresolvedGroupRow]
    let summary: VersionCompareSummary

    init(result: FunctionVersionMatchResult,
         oldFunctions: [String: VersionCompareFunctionRef],
         newFunctions: [String: VersionCompareFunctionRef]) {
        func old(_ id: String) -> VersionCompareFunctionRef {
            oldFunctions[id] ?? VersionCompareFunctionRef(id: id, address: nil, name: id)
        }
        func new(_ id: String) -> VersionCompareFunctionRef {
            newFunctions[id] ?? VersionCompareFunctionRef(id: id, address: nil, name: id)
        }
        func matchRow(_ match: FunctionVersionMatch) -> VersionCompareRow {
            VersionCompareRow(
                id: "match:\(match.oldID)>\(match.newID)",
                status: match.isChanged ? .changed : .unchanged,
                old: old(match.oldID), new: new(match.newID),
                basis: match.basis, confidence: match.confidence,
                differences: match.differences, symbolNameChanged: match.symbolNameChanged)
        }
        let changed = result.changedMatches.map(matchRow)
        let unchanged = result.unchangedMatches.map(matchRow)
        let removed = result.removedIDs.map {
            VersionCompareRow(id: "removed:\($0)", status: .removed, old: old($0), new: nil,
                              basis: nil, confidence: nil, differences: [], symbolNameChanged: false)
        }
        let added = result.addedIDs.map {
            VersionCompareRow(id: "added:\($0)", status: .added, old: nil, new: new($0),
                              basis: nil, confidence: nil, differences: [], symbolNameChanged: false)
        }
        rows = changed + removed + added + unchanged
        unresolvedGroups = result.unresolved.map { group in
            VersionCompareUnresolvedGroupRow(
                id: "group:" + group.oldIDs.joined(separator: ",") + ">" + group.newIDs.joined(separator: ","),
                old: group.oldIDs.map(old), new: group.newIDs.map(new), bases: group.bases)
        }
        summary = VersionCompareSummary(
            unchanged: unchanged.count, changed: changed.count, added: added.count,
            removed: removed.count, unresolvedGroups: result.unresolved.count,
            manualPins: result.manualPins.count)
    }

    func filteredRows(filter: VersionCompareFilter, search: String) -> [VersionCompareRow] {
        let query = Self.normalizedQuery(search)
        return rows.filter { row in
            let statusMatches: Bool = switch filter {
            case .all: true
            case .changed: row.status == .changed
            case .added: row.status == .added
            case .removed: row.status == .removed
            case .unchanged: row.status == .unchanged
            case .unresolved: false
            }
            return statusMatches && row.matches(query)
        }
    }

    func filteredUnresolvedGroups(filter: VersionCompareFilter, search: String) -> [VersionCompareUnresolvedGroupRow] {
        guard filter == .all || filter == .unresolved else { return [] }
        let query = Self.normalizedQuery(search)
        return unresolvedGroups.filter { $0.matches(query) }
    }

    static func normalizedQuery(_ search: String) -> String {
        search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

/// Everything one background comparison produces. The matcher is retained so manual pins can be
/// resolved against the exact inputs the published result came from.
struct VersionCompareComputation: Sendable {
    let matcher: FunctionVersionMatcher
    let result: FunctionVersionMatchResult
    let oldFunctions: [String: VersionCompareFunctionRef]
    let newFunctions: [String: VersionCompareFunctionRef]

    var report: VersionCompareReport {
        VersionCompareReport(result: result, oldFunctions: oldFunctions, newFunctions: newFunctions)
    }

    func replacingResult(_ result: FunctionVersionMatchResult) -> VersionCompareComputation {
        VersionCompareComputation(matcher: matcher, result: result,
                                  oldFunctions: oldFunctions, newFunctions: newFunctions)
    }

    /// Fingerprints both analyses and runs the matcher. Synchronous and CPU-bound: callers run it
    /// off the main actor. Cancellation is honored between the expensive stages.
    static func build(old: ImageAnalysis, new: ImageAnalysis) throws -> VersionCompareComputation {
        let oldFingerprints = FunctionVersionFingerprintAdapter.fingerprints(from: old)
        try Task.checkCancellation()
        let newFingerprints = FunctionVersionFingerprintAdapter.fingerprints(from: new)
        try Task.checkCancellation()
        let matcher = try FunctionVersionMatcher(old: oldFingerprints, new: newFingerprints)
        let result = try matcher.match()
        try Task.checkCancellation()
        return VersionCompareComputation(
            matcher: matcher, result: result,
            oldFunctions: refs(oldFingerprints, analysis: old),
            newFunctions: refs(newFingerprints, analysis: new))
    }

    private static func refs(_ fingerprints: [FunctionVersionFingerprint],
                             analysis: ImageAnalysis) -> [String: VersionCompareFunctionRef] {
        // The adapter keys fingerprints by `FunctionSummary.id`; show the analysis' own name
        // (which includes generated `sub_` names the matcher deliberately ignores as evidence).
        let names = Dictionary(analysis.functions.map { ($0.id.uuidString, $0.name) },
                               uniquingKeysWith: { first, _ in first })
        var refs: [String: VersionCompareFunctionRef] = [:]
        for fingerprint in fingerprints {
            refs[fingerprint.id] = VersionCompareFunctionRef(
                id: fingerprint.id, address: fingerprint.address,
                name: names[fingerprint.id] ?? fingerprint.symbolName ?? fingerprint.address.hexAddress)
        }
        return refs
    }
}

// MARK: - Labels

extension FunctionVersionMatchBasis {
    var compareLabel: String {
        switch self {
        case .manual: "Manual pin"
        case .symbolName: "Symbol name"
        case .normalizedBody: "Identical body"
        case .controlFlowAndCallees: "CFG + callees"
        case .callGraphPropagation: "Call-graph propagation"
        }
    }
}

extension FunctionVersionMatchConfidence {
    var compareLabel: String {
        switch self {
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        case .userConfirmed: "User-confirmed"
        }
    }
}

extension FunctionVersionDifference {
    var compareLabel: String {
        switch self {
        case .body: "body"
        case .controlFlow: "control flow"
        case .callees: "calls"
        case .size: "size"
        case .stringReferences: "strings"
        }
    }
}

extension FunctionVersionAmbiguityBasis {
    var compareLabel: String {
        switch self {
        case .duplicateSymbolName: "Duplicate symbol name"
        case .duplicateNormalizedBody: "Identical bodies"
        case .duplicateControlFlowAndCallees: "Identical CFG + callees"
        case .conflictingCallGraphCandidates: "Conflicting call-graph candidates"
        }
    }
}

extension FunctionVersionMatcherError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .duplicateOldID(let id): "The old image reports function \(id) more than once."
        case .duplicateNewID(let id): "The new image reports function \(id) more than once."
        case .unknownOldID(let id): "Function \(id) is not in the old image."
        case .unknownNewID(let id): "Function \(id) is not in the new image."
        case .oldAlreadyMatched(let id): "Old function \(id) is already matched."
        case .newAlreadyMatched(let id): "New function \(id) is already matched."
        case .conflictingPins: "Two manual pins claim the same function."
        }
    }
}

// MARK: - RX-01 annotation transfer review

/// The review the user selects from before names and comments move old → new. Built only from a
/// published comparison; every row is a 1:1 matcher pair whose OLD function start carries authored
/// text. Ambiguous groups, added and removed functions never become rows. Generated `sub_…`
/// analysis names never transfer (only authored `customName`/`customComment` text is read).
struct AnnotationTransferReview: Equatable {
    let pair: VersionComparePair
    let candidates: [AnnotationTransferCandidate]
    /// Candidate ids the user selected; never contains a skipped candidate.
    var selected: Set<String>
    /// Ambiguous groups the matcher refused to pair (pin one in Compare Images to include it).
    let unresolvedGroupCount: Int
    /// The plan for `selected`, or the planner's refusal.
    var preview: Result<AnnotationTransferPreview, AnnotationTransferError>

    var selectableIDs: Set<String> { Set(candidates.lazy.filter { $0.skip == nil }.map(\.id)) }
    var skipped: [AnnotationTransferCandidate] { candidates.filter { $0.skip != nil } }
    var plan: AnnotationTransferPreview? { try? preview.get() }
    var canApply: Bool { !(plan?.changes.isEmpty ?? true) }

    var applyTitle: String {
        guard let plan else { return "Apply Selected" }
        return "Apply \(plan.nameCount) \(plan.nameCount == 1 ? "name" : "names") and "
            + "\(plan.commentCount) \(plan.commentCount == 1 ? "comment" : "comments")"
    }
}

extension AnnotationTransferCandidate {
    /// What this row would move (from the old side's authored text), for display.
    var movesText: String {
        var parts: [String] = []
        if incoming.name != nil { parts.append("name") }
        if incoming.comment != nil { parts.append("comment") }
        return parts.joined(separator: " + ")
    }

    /// Why the matcher paired these two functions, plus any differences, for display.
    var reasonText: String {
        var parts = [basis.compareLabel]
        if !differences.isEmpty { parts.append("Δ " + differences.map(\.compareLabel).joined(separator: ", ")) }
        if symbolNameChanged { parts.append("renamed/stripped") }
        return parts.joined(separator: " · ")
    }
}

extension AnnotationTransferCandidate.SkipReason {
    var compareLabel: String {
        switch self {
        case .textLimit: "Text over the size limit or contains NUL"
        case .notFunctionStart: "New address is not a function start"
        }
    }
}

extension AnnotationTransferConflict.Kind {
    var compareLabel: String {
        switch self {
        case .authored: "Destination already has authored text"
        case .destinationSymbol: "Destination has a different real symbol"
        }
    }
}

extension AnnotationTransferError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .pairLimitExceeded(let count): "Too many pairs selected (\(count))."
        case .notOneToOne(let address): "Address \(address.hexAddress) appears in more than one pair."
        case .textLimitExceeded(let address): "Text at \(address.hexAddress) is over the transfer size limit."
        }
    }
}

extension AnnotationTransferRefusal {
    var message: String {
        func list(_ addresses: [UInt64]) -> String {
            let shown = addresses.prefix(5).map(\.hexAddress).joined(separator: ", ")
            return addresses.count > 5 ? shown + ", …" : shown
        }
        switch self {
        case .sameImage: return "Old and new are the same image."
        case .imageReplaced(let side): return "The \(side.rawValue) image was replaced after the comparison."
        case .analysisChanged(let side): return "The \(side.rawValue) image was re-analyzed after the comparison."
        case .reanalysisInFlight(let side): return "The \(side.rawValue) image is being re-analyzed."
        case .destinationChanged(let a): return "Names or comments changed at \(list(a)) in the new image."
        case .sourceChanged(let a): return "Names or comments changed at \(list(a)) in the old image."
        case .destinationNotFunctionStart(let a): return "\(list(a)) is no longer a function start."
        case .unexaminedDestination(let a): return "\(list(a)) was not part of the preview."
        }
    }
}

extension AnnotationTransferCommitOutcome {
    var message: String {
        switch self {
        case .applied(let names, let comments, let conflicts):
            "Transferred \(names) \(names == 1 ? "name" : "names") and \(comments) "
                + "\(comments == 1 ? "comment" : "comments"). \(conflicts) "
                + "\(conflicts == 1 ? "conflict" : "conflicts") left unchanged. Undo with ⌘Z."
        case .nothingToApply(let conflicts):
            "Nothing to transfer. \(conflicts) \(conflicts == 1 ? "conflict" : "conflicts") left unchanged."
        case .refused(let refusal):
            "Not applied: \(refusal.message) Rebuild the preview and try again."
        }
    }

    var isRefused: Bool { if case .refused = self { true } else { false } }
}

import Foundation

/// Stepping model for a binary `Find` result set: tracks a current position in an
/// ordered list of `BinarySearchResult`s and advances/retreats with wrap-around, so
/// the UI's Find-Next / Find-Previous (Cmd-G / Cmd-Shift-G) can walk every hit in a
/// stable order and cycle past the ends.
///
/// Pure value type — no SwiftUI, no store coupling — so the stepping logic is unit
/// testable on its own. The results are taken verbatim in the order the service
/// produced them (already de-duplicated, sorted by address, and capped), so the walk
/// order is the same stable address order the result list shows.
struct SearchResultCursor: Equatable {
    struct RetainedFindAuthority: Equatable, Sendable {
        let publicationID: UUID
        let workspaceOwner: ObjectIdentifier
        let workspaceID: UUID
        let documentID: UUID
        let revision: UInt64
        let imageOwners: [ImageSlot: UUID]
        let analysisFingerprints: [ImageSlot: String]
        let focusedSlot: ImageSlot
        let scope: BinarySearchScope
    }
    let retainedFindAuthority: RetainedFindAuthority?
    /// The ordered, stable result set being stepped through.
    private(set) var results: [BinarySearchResult]
    /// Index into `results` of the current hit, or `nil` before the first step
    /// (empty set, or freshly built and not yet advanced).
    private(set) var index: Int?

    /// Builds a cursor over `results`. A supplied selection matches both image and
    /// address, so colliding virtual addresses cannot seed a sibling image's hit.
    /// Otherwise the cursor starts unpositioned and `next()` selects the first result.
    init(results: [BinarySearchResult], selecting target: ImageAddress? = nil,
         retainedFindAuthority: RetainedFindAuthority? = nil) {
        self.retainedFindAuthority = retainedFindAuthority
        self.results = results
        self.index = target.flatMap { selected in
            results.firstIndex {
                $0.imageSlot == selected.slot && $0.address == selected.address
            }
        }
    }

    /// True when there is nothing to step through.
    var isEmpty: Bool { results.isEmpty }

    /// The number of results in the set.
    var count: Int { results.count }

    /// The currently-selected result, or nil when unpositioned/empty.
    var current: BinarySearchResult? {
        guard let index, results.indices.contains(index) else { return nil }
        return results[index]
    }

    /// A 1-based "k of N" position for a status line (e.g. "3 of 47"), or nil when
    /// empty or not yet positioned.
    var positionLabel: String? {
        guard let index, !results.isEmpty else { return nil }
        return "\(index + 1) of \(results.count)"
    }

    /// Advances to the next result and returns it, wrapping from the last back to the
    /// first. From the unpositioned state, selects the first result. Returns nil only
    /// when the set is empty.
    @discardableResult
    mutating func next() -> BinarySearchResult? {
        guard !results.isEmpty else { index = nil; return nil }
        if let current = index {
            index = (current + 1) % results.count
        } else {
            index = 0
        }
        return current
    }

    /// Retreats to the previous result and returns it, wrapping from the first back to
    /// the last. From the unpositioned state, selects the last result. Returns nil only
    /// when the set is empty.
    @discardableResult
    mutating func previous() -> BinarySearchResult? {
        guard !results.isEmpty else { index = nil; return nil }
        if let current = index {
            index = (current - 1 + results.count) % results.count
        } else {
            index = results.count - 1
        }
        return current
    }
}

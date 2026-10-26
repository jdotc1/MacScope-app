/*
MIT License

Copyright (c) 2026 EntitlementDiff contributors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
*/

import Foundation

public enum BrowserFilter: String, CaseIterable, Sendable {
    case allChanges, allKeys, added, removed, changed, unchanged
    public var label: String {
        switch self {
        case .allChanges: "All Changes"
        case .allKeys: "All Keys"
        case .added: "Added"
        case .removed: "Removed"
        case .changed: "Changed"
        case .unchanged: "Unchanged"
        }
    }
    public func includes(_ kind: ChangeKind) -> Bool {
        self == .allKeys || (self == .allChanges ? kind != .unchanged : rawValue == kind.rawValue)
    }
}

public struct BrowserSort: SortComparator, Sendable {
    public enum Column: Sendable { case key, change }
    public var column: Column
    public var order: SortOrder
    public init(column: Column = .key, order: SortOrder = .forward) {
        self.column = column
        self.order = order
    }
    private func rank(_ kind: ChangeKind) -> Int {
        switch kind { case .added: 0; case .removed: 1; case .changed: 2; case .unchanged: 3 }
    }
    public func compare(_ lhs: EntitlementChange, _ rhs: EntitlementChange) -> ComparisonResult {
        let result: ComparisonResult
        if column == .change, lhs.kind != rhs.kind {
            result = rank(lhs.kind) < rank(rhs.kind) ? .orderedAscending : .orderedDescending
        } else if lhs.key.utf8.elementsEqual(rhs.key.utf8) {
            result = .orderedSame
        } else {
            result = lhs.key.utf8.lexicographicallyPrecedes(rhs.key.utf8) ? .orderedAscending : .orderedDescending
        }
        if order == .forward { return result }
        return result == .orderedAscending ? .orderedDescending : result == .orderedDescending ? .orderedAscending : .orderedSame
    }
}

/// Session presentation only; never changes comparison or report contents.
/// The UI reads stored projections instead of filtering/sorting during body evaluation.
public struct ComparisonBrowser {
    public enum ChangeDirection: Sendable { case previous, next }

    /// Resolve only against the current stored visible order; hidden keys never participate.
    public func changeTarget(_ direction: ChangeDirection) -> String? {
        guard !visibleChangeIndices.isEmpty else { return nil }
        guard let selection, let index = visibleIndexByID[selection] else {
            let target = direction == .next ? visibleChangeIndices[0] : visibleChangeIndices[visibleChangeIndices.count - 1]
            return visibleRows[target].id
        }
        // Lower bound of the first change strictly after (next) or at (previous)
        // the selected visible index. Previous then chooses the preceding entry.
        var low = 0, high = visibleChangeIndices.count
        while low < high {
            let middle = low + (high - low) / 2
            if visibleChangeIndices[middle] < index || (direction == .next && visibleChangeIndices[middle] == index) {
                low = middle + 1
            } else { high = middle }
        }
        let ordinal = direction == .next ? low : low - 1
        guard visibleChangeIndices.indices.contains(ordinal) else { return nil }
        return visibleRows[visibleChangeIndices[ordinal]].id
    }

    @discardableResult
    public mutating func moveToChange(_ direction: ChangeDirection) -> String? {
        guard let target = changeTarget(direction) else { return nil }
        selection = target
        return target
    }

    public var changePositionText: String {
        if let selection, let ordinal = changeOrdinalByID[selection] {
            return "Change \(ordinal) of \(visibleChangeIndices.count) in this view"
        }
        return "Visible changes: \(visibleChangeIndices.count)"
    }

    public enum ExactFindResult: Equatable, Sendable {
        case found(String), hidden, missing
    }

    /// Explicit full-key lookup. Never trims, case-folds or normalizes Unicode.
    public mutating func findExactKey(_ key: String, revealHidden: Bool = false) -> ExactFindResult {
        guard let row = sourceRows.first(where: { $0.key.utf8.elementsEqual(key.utf8) }) else { return .missing }
        if visibleRowsByID[row.id] == nil {
            guard revealHidden else { return .hidden }
            preferences.filter = .allKeys
            preferences.query = ""
            refreshProjection()
        }
        selection = row.id
        return .found(row.id)
    }

    private struct Preferences {
        var filter: BrowserFilter = .allChanges
        var query = ""
        var sortOrder = [BrowserSort()]
    }
    private var preferences = Preferences()
    private var hasStoredSource = false
    private var sourceRows: [EntitlementChange] = []
    private var countsByKind: [ChangeKind: Int] = [:]
    private var visibleRowsByID: [String: EntitlementChange] = [:]
    private var visibleIndexByID: [String: Int] = [:]
    private var visibleChangeIndices: [Int] = []
    private var changeOrdinalByID: [String: Int] = [:]
    public private(set) var visibleRows: [EntitlementChange] = []

    public var filter: BrowserFilter {
        get { preferences.filter }
        set {
            guard newValue != preferences.filter else { return }
            preferences.filter = newValue
            refreshProjection()
        }
    }
    public var query: String {
        get { preferences.query }
        set {
            guard !newValue.utf8.elementsEqual(preferences.query.utf8) else { return }
            preferences.query = newValue
            refreshProjection()
        }
    }
    public var sortOrder: [BrowserSort] {
        get { preferences.sortOrder }
        set {
            guard newValue != preferences.sortOrder else { return }
            preferences.sortOrder = newValue
            refreshProjection()
        }
    }
    public var selection: String?
    public var selectedRow: EntitlementChange? { selection.flatMap { visibleRowsByID[$0] } }
    public init() {}
    public var isDefault: Bool { filter == .allChanges && query.isEmpty && sortOrder == [BrowserSort()] }

    /// Call for every new comparison, even if keys/IDs are identical after Reload.
    public mutating func replaceRows(_ rows: [EntitlementChange]) {
        hasStoredSource = true
        sourceRows = rows
        countsByKind = [:]
        for row in rows { countsByKind[row.kind, default: 0] += 1 }
        refreshProjection()
    }

    public func count(_ filter: BrowserFilter) -> Int {
        switch filter {
        case .allChanges: sourceRows.count - countsByKind[.unchanged, default: 0]
        case .allKeys: sourceRows.count
        case .added: countsByKind[.added, default: 0]
        case .removed: countsByKind[.removed, default: 0]
        case .changed: countsByKind[.changed, default: 0]
        case .unchanged: countsByKind[.unchanged, default: 0]
        }
    }

    public var recoveryGuidance: BrowserRecoveryGuidance? {
        guard hasStoredSource, visibleRows.isEmpty else { return nil }
        return BrowserRecoveryGuidance(filter: filter, hasQuery: !query.isEmpty,
                                       categoryCount: count(filter), keyCount: count(.allKeys),
                                       changeCount: count(.allChanges))
    }

    /// Apply only the action appropriate to the current projection, never a stale button.
    public mutating func recover(_ action: BrowserRecoveryGuidance.Action) {
        guard recoveryGuidance?.action == action else { return }
        switch action {
        case .clearSearch: preferences.query = ""
        case .showAllChanges: preferences.query = ""; preferences.filter = .allChanges
        case .showAllKeys: preferences.query = ""; preferences.filter = .allKeys
        }
        refreshProjection()
    }

    // Retain the stateless library helpers; the app uses the stored projection above.
    public func count(_ filter: BrowserFilter, in rows: [EntitlementChange]) -> Int {
        rows.filter { filter.includes($0.kind) }.count
    }
    public func visibleRows(in rows: [EntitlementChange]) -> [EntitlementChange] {
        rows.filter { filter.includes($0.kind) && (query.isEmpty || $0.key.localizedCaseInsensitiveContains(query)) }
            .sorted { lhs, rhs in
                for comparator in sortOrder {
                    let result = comparator.compare(lhs, rhs)
                    if result != .orderedSame { return result == .orderedAscending }
                }
                return lhs.key.utf8.lexicographicallyPrecedes(rhs.key.utf8)
            }
    }
    public mutating func reconcileSelection(in visibleRows: [EntitlementChange]) {
        if let selection, !visibleRows.contains(where: { $0.id == selection }) { self.selection = nil }
    }
    public mutating func reset() {
        guard !isDefault else { return }
        preferences = Preferences()
        refreshProjection()
    }

    private mutating func refreshProjection() {
        // Stateless callers still own their rows and reconcile selection explicitly.
        guard hasStoredSource else { return }
        visibleRows = visibleRows(in: sourceRows)
        visibleRowsByID = [:]
        visibleIndexByID = [:]; visibleChangeIndices = []; changeOrdinalByID = [:]
        for (index, row) in visibleRows.enumerated() {
            visibleRowsByID[row.id] = row
            visibleIndexByID[row.id] = index
            if row.kind != .unchanged {
                visibleChangeIndices.append(index)
                changeOrdinalByID[row.id] = visibleChangeIndices.count
            }
        }
        if let selection, visibleRowsByID[selection] == nil { self.selection = nil }
    }
}

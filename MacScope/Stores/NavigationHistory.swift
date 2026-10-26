import Foundation

/// Browser-style back/forward navigation history of visited addresses.
///
/// A pure value type so the back/forward/truncate/cap logic is unit-testable
/// independent of the store. `record` appends a new current location; recording
/// while not at the end truncates the forward list (the standard "you went back,
/// then somewhere new" behavior), consecutive duplicates are ignored, and the list
/// is capped to `maxEntries` (oldest dropped).
/// One presentation-ready row in the browsable navigation-history panel: a visited
/// address with its resolved symbol/section context and whether it is the current cursor.
/// `panelIndex` is the entry's index in the underlying `NavigationHistory.locations`
/// (passed back to `navigateToHistoryEntry(at:)` on selection). A pure value type so the
/// panel and its tests render rows without touching the store.
struct NavigationHistoryRow: Identifiable, Equatable {
    let panelIndex: Int
    let address: UInt64
    let symbolName: String?
    let sectionName: String?
    let isCurrent: Bool
    var imageName: String? = nil

    /// The live store supplies a monotonic visit token, preserving row identity through
    /// pruning and preventing a retained callback from being rebound to a replacement row.
    var id: Int { panelIndex }

    /// The primary label: the resolved symbol/function name, else the bare hex address.
    var title: String { symbolName ?? address.hexAddress }

    /// The secondary label: the hex address (when a symbol owns the title) plus the section,
    /// joined for an accessibility-friendly one-line context string.
    var subtitle: String {
        var parts: [String] = []
        if let imageName { parts.append(imageName) }
        if symbolName != nil { parts.append(address.hexAddress) }
        if let sectionName { parts.append(sectionName) }
        return parts.joined(separator: "  •  ")
    }
}

/// A transient visit belongs to one live document owner, never just to an address.
struct WorkspaceNavigationLocation: Equatable, Sendable {
    let sessionID: UUID
    let workspaceID: UUID
    let documentID: UUID
    let target: ImageAddress
    let binaryID: UUID?
    let editorMode: EditorMode
}

/// Owner-qualified history used by the live store. Tokens survive pruning and resets so a
/// retained panel callback cannot accidentally select a newly inserted row at the same index.
struct WorkspaceNavigationHistory: Equatable, Sendable {
    struct Entry: Equatable, Sendable {
        let token: Int
        let location: WorkspaceNavigationLocation
    }
    private(set) var entries: [Entry] = []
    private(set) var index = -1
    private var nextToken = 0
    let maxEntries: Int

    init(maxEntries: Int = 200) { self.maxEntries = max(1, maxEntries) }
    var current: WorkspaceNavigationLocation? {
        entries.indices.contains(index) ? entries[index].location : nil
    }
    var canGoBack: Bool { index > 0 }
    var canGoForward: Bool { index >= 0 && index + 1 < entries.count }

    mutating func record(_ location: WorkspaceNavigationLocation) {
        guard current != location, nextToken < Int.max else { return }
        if index + 1 < entries.count { entries.removeSubrange((index + 1)...) }
        entries.append(.init(token: nextToken, location: location))
        nextToken += 1
        if entries.count > maxEntries { entries.removeFirst(entries.count - maxEntries) }
        index = entries.count - 1
    }

    mutating func goBack() -> WorkspaceNavigationLocation? {
        guard canGoBack else { return nil }
        index -= 1
        return current
    }
    mutating func goForward() -> WorkspaceNavigationLocation? {
        guard canGoForward else { return nil }
        index += 1
        return current
    }
    mutating func updateCurrent(_ location: WorkspaceNavigationLocation) {
        guard entries.indices.contains(index), current?.target == location.target,
              current?.binaryID == location.binaryID else { return }
        entries[index] = .init(token: entries[index].token, location: location)
    }
    mutating func jump(to token: Int) -> WorkspaceNavigationLocation? {
        guard let found = entries.firstIndex(where: { $0.token == token }) else { return nil }
        index = found
        return current
    }
    var panelEntries: [(panelIndex: Int, location: WorkspaceNavigationLocation, isCurrent: Bool)] {
        entries.indices.reversed().map { (entries[$0].token, entries[$0].location, $0 == index) }
    }
    mutating func reset(seed: WorkspaceNavigationLocation? = nil) {
        entries.removeAll()
        index = -1
        if let seed { record(seed) }
    }
    mutating func prune(keeping isValid: (WorkspaceNavigationLocation) -> Bool) {
        let currentToken = entries.indices.contains(index) ? entries[index].token : nil
        let priorEntries = entries
        let priorIndex = index
        entries.removeAll { !isValid($0.location) }
        if let currentToken, let retained = entries.firstIndex(where: { $0.token == currentToken }) {
            index = retained
        } else {
            // Choose the latest retained visit before the removed cursor. This preserves
            // forward navigation without making a newly replaced owner current.
            let predecessors = Set(priorEntries.prefix(max(0, priorIndex)).map(\.token))
            index = entries.lastIndex(where: { predecessors.contains($0.token) }) ?? -1
        }
    }
}

struct NavigationHistory: Equatable, Sendable {
    private(set) var locations: [UInt64] = []
    /// Index of the current location within `locations`, or -1 when empty.
    private(set) var index: Int = -1
    let maxEntries: Int

    init(maxEntries: Int = 200) {
        self.maxEntries = max(1, maxEntries)
    }

    var current: UInt64? {
        locations.indices.contains(index) ? locations[index] : nil
    }

    var canGoBack: Bool { index > 0 }
    var canGoForward: Bool { index >= 0 && index < locations.count - 1 }

    /// Records a jump to `address` as the new current location.
    mutating func record(_ address: UInt64) {
        if current == address { return } // ignore consecutive duplicates
        if index < locations.count - 1 {
            locations.removeSubrange((index + 1)...) // dropped forward history
        }
        locations.append(address)
        index = locations.count - 1
        if locations.count > maxEntries {
            let overflow = locations.count - maxEntries
            locations.removeFirst(overflow)
            index -= overflow
        }
    }

    /// Moves back one entry and returns the address to navigate to, or nil at the start.
    mutating func goBack() -> UInt64? {
        guard canGoBack else { return nil }
        index -= 1
        return locations[index]
    }

    /// Moves forward one entry and returns the address to navigate to, or nil at the end.
    mutating func goForward() -> UInt64? {
        guard canGoForward else { return nil }
        index += 1
        return locations[index]
    }

    /// Moves the cursor directly to `targetIndex` (a row chosen in the history panel) and
    /// returns the address there, or nil for an out-of-range index. Unlike `record`, this
    /// NEVER truncates the forward list — jumping to an older entry then forward again must
    /// still work, exactly like Back/Forward. Jumping to the current index is a no-op that
    /// still returns its address (so the panel can re-center selection without side effects).
    mutating func jump(to targetIndex: Int) -> UInt64? {
        guard locations.indices.contains(targetIndex) else { return nil }
        index = targetIndex
        return locations[targetIndex]
    }

    /// The visited locations newest-first, each paired with whether it is the current
    /// cursor. Used to drive the browsable history panel (which lists most-recent-on-top).
    /// `panelIndex` is the ORIGINAL index in `locations` — pass it back to `jump(to:)`.
    var panelEntries: [(panelIndex: Int, address: UInt64, isCurrent: Bool)] {
        locations.indices.reversed().map { i in
            (panelIndex: i, address: locations[i], isCurrent: i == index)
        }
    }

    /// Clears the history and optionally seeds it with a starting location (e.g. the
    /// entry point when a new binary is loaded), so the first Back returns there.
    mutating func reset(seed: UInt64? = nil) {
        if let seed {
            locations = [seed]
            index = 0
        } else {
            locations = []
            index = -1
        }
    }
}

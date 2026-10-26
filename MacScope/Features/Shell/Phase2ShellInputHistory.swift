import Foundation

struct Phase2ShellInputHistory: Equatable, Sendable {
    private(set) var entries: [String]
    private(set) var cursor: Int?
    private var draft: String
    private let maximumEntries: Int

    init(
        entries: [String] = [],
        cursor: Int? = nil,
        draft: String = "",
        maximumEntries: Int = AppShellChrome.maximumInputHistoryEntries
    ) {
        self.maximumEntries = max(1, maximumEntries)
        let boundedEntries = Array(entries.suffix(self.maximumEntries))
        self.entries = boundedEntries
        self.cursor = cursor.flatMap { boundedEntries.indices.contains($0) ? $0 : nil }
        self.draft = draft
    }

    var canNavigatePrevious: Bool {
        !entries.isEmpty && cursor != entries.startIndex
    }

    var canNavigateNext: Bool {
        cursor != nil
    }

    mutating func commit(_ input: String) {
        let normalized = input.trimmingCharacters(in: .whitespacesAndNewlines)
        cursor = nil
        draft = ""
        guard !normalized.isEmpty else { return }
        entries.removeAll { $0 == normalized }
        entries.append(normalized)
        if entries.count > maximumEntries {
            entries.removeFirst(entries.count - maximumEntries)
        }
    }

    mutating func previous(currentDraft: String) -> String? {
        guard canNavigatePrevious else { return nil }
        if let cursor {
            let nextCursor = entries.index(before: cursor)
            self.cursor = nextCursor
            return entries[nextCursor]
        }
        draft = currentDraft
        let nextCursor = entries.index(before: entries.endIndex)
        cursor = nextCursor
        return entries[nextCursor]
    }

    mutating func next() -> String? {
        guard let cursor else { return nil }
        let afterCursor = entries.index(after: cursor)
        guard afterCursor < entries.endIndex else {
            self.cursor = nil
            let restoredDraft = draft
            draft = ""
            return restoredDraft
        }
        self.cursor = afterCursor
        return entries[afterCursor]
    }

    mutating func resetNavigation() {
        cursor = nil
        draft = ""
    }
}

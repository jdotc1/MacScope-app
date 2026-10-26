import Foundation

/// Back/forward history for the Settings window, the way System Settings navigates.
struct SettingsHistory<Page: Hashable>: Equatable {
    private(set) var backStack: [Page] = []
    private(set) var forwardStack: [Page] = []

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }

    /// Records a move from `current` to `next`. A new visit clears the forward stack.
    mutating func visit(from current: Page, to next: Page) {
        guard current != next else { return }
        backStack.append(current)
        forwardStack.removeAll()
    }

    /// The page to show after going back from `current`, or `nil` at the start of history.
    mutating func goBack(from current: Page) -> Page? {
        guard let previous = backStack.popLast() else { return nil }
        forwardStack.append(current)
        return previous
    }

    /// The page to show after going forward from `current`, or `nil` at the end of history.
    mutating func goForward(from current: Page) -> Page? {
        guard let next = forwardStack.popLast() else { return nil }
        backStack.append(current)
        return next
    }
}

/// Settings search: a category matches when every word of the query appears in its title or in
/// the labels of the settings it contains. Case- and diacritic-insensitive.
enum SettingsSearch {
    static func matches(query: String, title: String, keywords: [String]) -> Bool {
        let words = query
            .split(whereSeparator: \.isWhitespace)
            .map { $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) }
        guard !words.isEmpty else { return true }
        let haystack = ([title] + keywords)
            .joined(separator: " ")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        return words.allSatisfy { haystack.contains($0) }
    }
}

extension SettingsCategory {
    /// The settings and policy information in this category, so search finds it by what it
    /// contains ("utf-16", "stop at entry", "midnight"), not only by its name.
    var searchKeywords: [String] {
        switch self {
        case .analysis:
            ["uppercase addresses",
             "instruction bytes", "show addresses", "operand spacing", "workspace packages",
             "copy inputs", "attachments", ".mscope"]
        case .decompiler:
            ["control flow", "structured", "goto", "dead code", "returns", "nop", "padding",
             "simplification", "structuring budget", "function size"]
        case .appearance:
            ["theme", "editor theme", "window theme", "appearance", "light", "dark", "automatic",
             "scope", "midnight", "contrast", "colors", "listing font", "font size", "sf mono",
             "menlo", "monaco", "system accent", "accent color", "density", "compact", "comfortable",
             "theme editor", "inherits"]
        case .keysAndDisplay:
            ["keyboard shortcuts", "key bindings", "string display", "encoding", "utf-8", "utf-16",
             "ascii", "hex dump"]
        case .colorTags:
            ["color tags", "highlight", "labels", "tags"]
        case .plugins:
            ["plugins", "extensions", "trust", "signed", "development", "network access",
             "process spawning", "permissions"]
        case .debugger:
            ["lldb", "debugger", "live controls", "stop at entry", "launch", "attach", "breakpoints"]
        case .localAI:
            ["local ai", "mtplx", "model", "provider", "assistant", "ask macscope", "reasoning", "thinking"]
        }
    }

    static func matching(_ query: String) -> [SettingsCategory] {
        allCases.filter { SettingsSearch.matches(query: query, title: $0.title, keywords: $0.searchKeywords) }
    }
}

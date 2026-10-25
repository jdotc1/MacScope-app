import SwiftUI
import LumenTokens
import LumenUI

// Find, completion and navigation pieces, live.

struct SearchPage: View {
    @State private var find = LumenFindQuery(pattern: "LumenStat")
    @State private var scope = "In Project"
    @State private var collapsed: Set<String> = []
    @State private var opened = "Click a match to open it."
    @State private var highlight = "theme"
    @State private var goesToLine = false
    @State private var line = "No line chosen yet"
    @State private var typed = "Any"
    @State private var completion: String? = "AnyCollection"
    @State private var accepted = ""
    @State private var togglePanel: KeyboardShortcut? = KeyboardShortcut("y", modifiers: [.command, .shift])
    @State private var goToLine: KeyboardShortcut?
    @State private var jump: KeyboardShortcut? = KeyboardShortcut("l", modifiers: [.command, .option])
    @State private var filter = "All"

    /// The project the find panel searches: a few files and their lines.
    private static let corpus: [(id: String, name: String, systemImage: String, hue: LumenToken, lines: [String])] = [
        ("dbg", "LumenDebugger.swift", "swift", .hueOrange, [
            "import SwiftUI", "", "/// A count with a label.", "public struct LumenStat: Identifiable {",
            "    public let label: String", "    public let count: Int", "}", "", "let stats: [LumenStat] = []",
        ]),
        ("themes", "LumenThemeStore.swift", "swift", .hueOrange, [
            "public final class LumenThemeStore {", "    public var themes: [LumenTheme] = []",
            "    public func select(_ id: String) {}", "}",
        ]),
        ("log", "CHANGELOG.md", "doc.text", .hueBlue, [
            "# Changelog", "", "## 0.18.0", "- `LumenStat`, `LumenStatsCard`", "- Theme miniatures",
        ]),
    ]

    private static let completions = [
        LumenCompletion("AnyClass", detail: "any AnyObject.Type", kind: .type),
        LumenCompletion("AnyCollection", detail: "AnyCollection<Element>", kind: .structure),
        LumenCompletion("AnyObject", detail: "protocol", kind: .type),
        LumenCompletion("anyMatches(_:)", detail: "(String) -> Bool", kind: .function),
        LumenCompletion("anchor", detail: "UnitPoint", kind: .property),
        LumenCompletion("async", kind: .keyword),
        LumenCompletion("assert(_:_:)", detail: "(Bool, String)", kind: .function),
        LumenCompletion("guard let", detail: "guard let x = … else { }", kind: .snippet),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PageHeader(title: "Search & Navigation", summary: "Find in project with grouped results, match highlighting, Go To Line, completions, shortcut recorders and filter chips. Press ⌘K for the command palette: type / for pages, > for commands or @ for themes.")

            LumenSectionHeader("Find in project")
            VStack(alignment: .leading, spacing: 0) {
                LumenFindPanel(query: $find, scope: $scope, scopes: ["In Project", "Open Files"], scopeTitle: { $0 },
                               onFind: {}, onReplaceAll: replaceAll)
                LumenSearchResults(results, collapsed: $collapsed) { file, match in
                    opened = "Opened \(file.name) at line \(match.line)"
                }
            }
            .frame(width: 320)
            .lumenSidebarBackground()
            .clipShape(.rect(cornerRadius: 8))
            Text(opened).font(.caption).foregroundStyle(.lumen(.fgTertiary))

            LumenSectionHeader("Highlighted matches")
            VStack(alignment: .leading, spacing: 8) {
                TextField("Highlight", text: $highlight).textFieldStyle(.roundedBorder).frame(width: 200)
                ForEach(["Use the Ultraviolet theme", "Themes folder", "Increase Contrast variants of every theme"], id: \.self) { text in
                    HStack(spacing: 16) {
                        LumenHighlightedText(text, matching: highlight)
                        LumenHighlightedText(text, matching: highlight, style: .emphasis)
                    }
                }
            }

            LumenSectionHeader("Go to Line")
            HStack(spacing: 12) {
                Button("Go to Line…", systemImage: "number") { goesToLine = true }
                    .popover(isPresented: $goesToLine, arrowEdge: .bottom) {
                        LumenInputPalette("Go to Line", systemImage: "number", hue: .hueGraphite,
                                          help: "Enter a line number (“12”) or a line and column (“12:30”).",
                                          isValid: { LumenGoToLine.parse($0) != nil },
                                          onSubmit: { text in
                                              if let target = LumenGoToLine.parse(text) {
                                                  line = "Line \(target.line)" + (target.column.map { ", column \($0)" } ?? "")
                                              }
                                              goesToLine = false
                                          },
                                          onDismiss: { goesToLine = false })
                            .padding(8)
                    }
                Text(line).font(.callout).foregroundStyle(.lumen(.fgSecondary))
            }

            LumenSectionHeader("Completions")
            VStack(alignment: .leading, spacing: 8) {
                TextField("Type", text: $typed).textFieldStyle(.roundedBorder).font(.body.monospaced()).frame(width: 200)
                let items = Self.completions.filter { typed.isEmpty || $0.name.lowercased().hasPrefix(typed.lowercased()) }
                if items.isEmpty {
                    Text("No completions for “\(typed)”.").font(.caption).foregroundStyle(.lumen(.fgTertiary))
                } else {
                    LumenCompletionList(items, typed: typed, selection: $completion) { accepted = $0.name }
                        .frame(width: 320)
                }
                if !accepted.isEmpty { Text("Accepted \(accepted)").font(.caption).foregroundStyle(.lumen(.fgTertiary)) }
            }

            LumenSectionHeader("Shortcut recorders")
            VStack(alignment: .leading, spacing: 6) {
                recorder("Toggle Panel", $togglePanel)
                recorder("Go to Line…", $goToLine)
                recorder("Jump to Selection", $jump, conflict: jump == KeyboardShortcut("l", modifiers: [.command, .option]) ? "Also used by Run Latest Test" : nil)
            }
            .frame(width: 320)

            LumenSectionHeader("Filter chips")
            LumenFilterChips(selection: $filter, groups: [["All"], ["Menu", "Extensions"], ["Customized", "Conflicts"]],
                             title: { $0 }, count: { $0 == "Conflicts" ? 2 : $0 == "Customized" ? 5 : nil })
            Text("Showing: \(filter)").font(.caption).foregroundStyle(.lumen(.fgTertiary))
        }
    }

    private func recorder(_ title: String, _ shortcut: Binding<KeyboardShortcut?>, conflict: String? = nil) -> some View {
        HStack {
            Text(title).font(.callout)
            Spacer()
            LumenShortcutRecorder(shortcut: shortcut, conflict: conflict)
        }
    }

    /// The corpus searched for the find panel's pattern (contains, case-insensitive unless asked).
    private var results: [LumenSearchFile] {
        let pattern = find.pattern
        guard !pattern.isEmpty else { return [] }
        return Self.corpus.compactMap { file in
            let matches = file.lines.enumerated().compactMap { index, text -> LumenSearchMatch? in
                let ranges = Self.ranges(of: pattern, in: text, caseSensitive: find.caseSensitive)
                return ranges.isEmpty ? nil : LumenSearchMatch(line: index + 1, text: text, ranges: ranges)
            }
            return matches.isEmpty ? nil : LumenSearchFile(id: file.id, name: file.name, systemImage: file.systemImage, hue: file.hue,
                                                           matches: matches)
        }
    }

    private static func ranges(of pattern: String, in text: String, caseSensitive: Bool) -> [Range<Int>] {
        let haystack = Array(caseSensitive ? text : text.lowercased())
        let needle = Array(caseSensitive ? pattern : pattern.lowercased())
        guard needle.count <= haystack.count else { return [] }
        var ranges: [Range<Int>] = []
        var start = 0
        while start + needle.count <= haystack.count {
            if Array(haystack[start..<start + needle.count]) == needle {
                ranges.append(start..<start + needle.count)
                start += needle.count
            } else {
                start += 1
            }
        }
        return ranges
    }

    private func replaceAll() {
        opened = find.replacement.isEmpty ? "Type a replacement first." : "Would replace \(results.flatMap(\.matches).count) matches."
    }
}

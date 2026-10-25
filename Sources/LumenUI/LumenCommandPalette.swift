import AppKit
import SwiftUI
import LumenTokens

// The command palette: every command an app has, found by typing. It floats over the window like
// an open-quickly search, matches forgivingly ("tgp" finds Toggle Panel), lists recent commands first,
// shows each command's shortcut so people learn it, and runs with Return. ⌘K opens it, and it's in
// the View menu through LumenViewCommands.

/// One command the palette can run.
public struct LumenCommand: Identifiable {
    public let id: String
    public let title: String
    public let subtitle: String?
    /// Where it belongs ("View", "Go", "Theme"); the palette groups by it and shows it on each row.
    public let category: String
    public let systemImage: String
    public let hue: LumenToken
    public let shortcut: KeyboardShortcut?
    /// Other words that should find it.
    public let keywords: [String]
    public let isEnabled: Bool
    public let perform: @MainActor () -> Void
    /// The `LumenPaletteScope` it's listed under besides All (a file in Files, a function in Symbols).
    public var scope: String?
    /// Shown at the row's trailing edge in place of the category (a file's relative path).
    public var detail: String?

    public init(id: String? = nil, _ title: String, subtitle: String? = nil, category: String, systemImage: String,
                hue: LumenToken = .accent, shortcut: KeyboardShortcut? = nil, keywords: [String] = [], isEnabled: Bool = true,
                scope: String?, detail: String? = nil, perform: @escaping @MainActor () -> Void) {
        self.init(id: id, title, subtitle: subtitle, category: category, systemImage: systemImage, hue: hue, shortcut: shortcut,
                  keywords: keywords, isEnabled: isEnabled, perform: perform)
        self.scope = scope
        self.detail = detail
    }

    public init(id: String? = nil, _ title: String, subtitle: String? = nil, category: String, systemImage: String,
                hue: LumenToken = .accent, shortcut: KeyboardShortcut? = nil, keywords: [String] = [], isEnabled: Bool = true,
                perform: @escaping @MainActor () -> Void) {
        self.id = id ?? "\(category).\(title)"
        self.title = title
        self.subtitle = subtitle
        self.category = category
        self.systemImage = systemImage
        self.hue = hue
        self.shortcut = shortcut
        self.keywords = keywords
        self.isEnabled = isEnabled
        self.perform = perform
    }
}

/// A part of the palette (Files, Symbols, Commands), chosen from its pill or by typing its prefix
/// first ("#comp" searches Symbols for "comp").
public struct LumenPaletteScope: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    /// Typed first to switch to this scope; `nil` for the scope that lists everything.
    public let prefix: Character?
    public let placeholder: String?

    public init(_ title: String, id: String? = nil, prefix: Character?, placeholder: String? = nil) {
        self.id = id ?? title
        self.title = title
        self.prefix = prefix
        self.placeholder = placeholder
    }

    /// The scope a query names by its first character, and the query without it. With no matching
    /// prefix, the scope that lists everything (or the first) and the whole query.
    static func resolve(_ query: String, in scopes: [LumenPaletteScope]) -> (scope: LumenPaletteScope?, query: String) {
        if let first = query.first, let scope = scopes.first(where: { $0.prefix == first }) {
            return (scope, String(query.dropFirst()))
        }
        return (scopes.first { $0.prefix == nil } ?? scopes.first, query)
    }

    /// Whether a command shows in this scope: everything in the scope without a prefix, otherwise
    /// commands whose `scope` is this one's id.
    func includes(_ command: LumenCommand) -> Bool { prefix == nil || command.scope == id }
}

// MARK: Matching

/// Forgiving, ranked matching. In titles the query's characters must appear in order; matches at the
/// start of the title and of words, and runs of consecutive characters, rank higher. Keywords and
/// categories match only at the start of a word ("pan" finds the Panel category, not "appearance"),
/// and rank below every title match.
enum LumenCommandMatcher {
    struct Match: Equatable {
        let score: Int
        /// Matched character offsets in the title (empty when only a keyword matched).
        let offsets: [Int]
    }

    static func match(_ query: String, title: String, keywords: [String] = []) -> Match? {
        let needle = fold(query).filter { !$0.isWhitespace }
        guard !needle.isEmpty else { return Match(score: 0, offsets: []) }
        return match(needle, Prepared(title: title, keywords: keywords))
    }

    /// A command's title and keywords folded once, so typing doesn't refold every title per keystroke.
    struct Prepared {
        let hay: [Character]
        let wordStart: [Bool]
        let words: [Substring]

        init(title: String, keywords: [String]) {
            let hay = LumenCommandMatcher.fold(title)
            self.hay = hay
            wordStart = hay.indices.map { $0 == 0 || !hay[$0 - 1].isLetter && !hay[$0 - 1].isNumber }
            words = keywords.flatMap { String(LumenCommandMatcher.fold($0)).split(whereSeparator: { !$0.isLetter && !$0.isNumber }) }
        }
    }

    static func match(_ needle: [Character], _ prepared: Prepared) -> Match? {
        if let titleMatch = score(needle, in: prepared) { return titleMatch }
        let prefix = String(needle)
        return prepared.words.contains { $0.hasPrefix(prefix) } ? Match(score: -100, offsets: []) : nil
    }

    /// Lowercased and without accents ("Café" → "cafe"), one character for each of the text's, so
    /// offsets still point into the title.
    static func fold(_ text: String) -> [Character] {
        text.map { character in
            // ASCII (most titles) needs only lowercasing; the general fold is far slower.
            if character.isASCII { return Character(character.lowercased()) }
            return String(character).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).first ?? character
        }
    }

    /// The best placement of the query's characters in order: each character scores 1, plus 8 at the
    /// start of a word and 8 right after the previous match, less the distance skipped (at most 6;
    /// reaching the start of a word for the first character is free). Considers every placement,
    /// so "pan" takes "Panel" in "Open Panel", not the "p" of "Open".
    private static func score(_ needle: [Character], in prepared: Prepared) -> Match? {
        let hay = prepared.hay, wordStart = prepared.wordStart
        let n = needle.count, m = hay.count
        guard n <= m else { return nil }
        // Cheap rejection first: the characters must appear in order at all.
        var next = 0
        for character in hay where next < n && character == needle[next] { next += 1 }
        guard next == n else { return nil }
        let none = Int.min / 2
        // best[i * m + j]: the best score with needle[0...i] placed and needle[i] at hay[j];
        // from[i * m + j]: the previous j. One flat buffer each (PERF-02: nested arrays allocated n + 1 per title).
        var best = [Int](repeating: none, count: n * m)
        var from = [Int](repeating: -1, count: n * m)
        for j in 0..<m where hay[j] == needle[0] {
            best[j] = 1 + (wordStart[j] ? 8 : 0) - (wordStart[j] ? 0 : min(j, 6))
        }
        if n > 1 {
            for i in 1..<n {
                let row = i * m, previousRow = (i - 1) * m
                // The best earlier placement far enough back that the skip cost is capped.
                var farBest = none, farFrom = -1
                for j in i..<m {
                    let far = j - 7
                    if far >= 0, best[previousRow + far] > farBest { farBest = best[previousRow + far]; farFrom = far }
                    guard hay[j] == needle[i] else { continue }
                    var top = farBest == none ? none : farBest - 6, topFrom = farFrom
                    for previous in max(0, j - 6)..<j where best[previousRow + previous] != none {
                        let gain = previous == j - 1 ? 8 : -(j - previous - 1)
                        if best[previousRow + previous] + gain > top { top = best[previousRow + previous] + gain; topFrom = previous }
                    }
                    guard top != none else { continue }
                    best[row + j] = top + 1 + (wordStart[j] ? 8 : 0)
                    from[row + j] = topFrom
                }
            }
        }
        let last = (n - 1) * m
        guard let end = (0..<m).filter({ best[last + $0] != none }).max(by: { best[last + $0] < best[last + $1] }) else { return nil }
        var offsets = [end]
        for i in stride(from: n - 1, to: 0, by: -1) { offsets.insert(from[i * m + offsets[0]], at: 0) }
        var score = best[last + end]
        if hay.starts(with: needle) { score += 20 }
        return Match(score: score - m / 10, offsets: offsets)
    }

    /// The palette's rows: with no query, recent commands then the rest in their given order;
    /// with a query, matches by score (ties keep the given order).
    /// Commands must have distinct IDs (they key rows, the highlight and recents); a later command
    /// with an ID already listed is left out.
    static func rows(_ commands: [LumenCommand], query: String, recents: [String]) -> [(command: LumenCommand, offsets: [Int], isRecent: Bool)] {
        rows(commands, query: query, recents: recents) { Prepared(title: $0.title, keywords: $0.keywords + [$0.category]) }
    }

    /// `rows` with each command's folded title supplied (the palette keeps them per command set).
    static func rows(_ commands: [LumenCommand], query: String, recents: [String],
                     prepared: (LumenCommand) -> Prepared) -> [(command: LumenCommand, offsets: [Int], isRecent: Bool)] {
        var seen = Set<String>()
        let commands = commands.filter { seen.insert($0.id).inserted }
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            let recentIDs = Set(recents)
            let byID = Dictionary(commands.filter { recentIDs.contains($0.id) }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let recent = recents.compactMap { byID[$0] }
            let shown = Set(recent.map(\.id))
            let rest = commands.filter { !shown.contains($0.id) }
            return recent.map { ($0, [], true) } + rest.map { ($0, [], false) }
        }
        let needle = fold(trimmed).filter { !$0.isWhitespace }
        return commands.enumerated()
            .compactMap { index, command in
                (needle.isEmpty ? Match(score: 0, offsets: []) : match(needle, prepared(command))).map { (index, command, $0) }
            }
            .sorted { $0.2.score != $1.2.score ? $0.2.score > $1.2.score : $0.0 < $1.0 }
            .map { ($0.1, $0.2.offsets, false) }
    }
}

/// The last few commands run, per app, in UserDefaults.
public struct LumenCommandRecents {
    public let key: String
    public let defaults: UserDefaults
    public static let limit = 5

    public init(key: String, defaults: UserDefaults = .standard) {
        self.key = key
        self.defaults = defaults
    }

    public var ids: [String] { defaults.stringArray(forKey: key) ?? [] }

    /// Records a run command first. With `among`, IDs no longer in it are dropped, so commands an app
    /// removed don't hold recent slots.
    public func record(_ id: String, among known: [String]? = nil) {
        let kept = ids.filter { $0 != id && known?.contains($0) != false }
        defaults.set(Array(([id] + kept).prefix(Self.limit)), forKey: key)
    }
}

// MARK: Palette

/// The palette itself: a search field over ranked commands, with tiles, categories and keycaps.
/// ↑/↓ move, Return runs, Escape closes.
public struct LumenCommandPalette: View {
    private let commands: [LumenCommand]
    private let scopes: [LumenPaletteScope]
    private let recents: LumenCommandRecents?
    private let fixedRecents: [String]?
    /// Snapshots draw the query as text and the results without a scroll view (offscreen rendering
    /// can't draw either native view).
    private let isSnapshot: Bool
    private let onDismiss: () -> Void

    @State private var query: String
    @State private var highlighted: String?
    @FocusState private var searchFocused: Bool
    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenMetrics) private var metrics
    @Environment(\.lumenDensity) private var density
    @Environment(\.lumenRendersOffscreen) private var rendersOffscreen

    /// The widest the palette gets; in a narrower window it narrows to fit (the host keeps a margin).
    static let width: CGFloat = 580

    /// - Parameter recentsKey: where recent commands are kept; `nil` keeps none.
    public init(_ commands: [LumenCommand], query: String = "", recentsKey: String? = "lumen.commandPalette.recents",
                onDismiss: @escaping () -> Void = {}) {
        self.init(commands, scopes: [], query: query, recentsKey: recentsKey, onDismiss: onDismiss)
    }

    /// - Parameter scopes: shown as pills under the field, each prefix in a keycap;
    ///   typing a prefix first switches scope. Empty shows no scope bar.
    public init(_ commands: [LumenCommand], scopes: [LumenPaletteScope], query: String = "",
                recentsKey: String? = "lumen.commandPalette.recents", onDismiss: @escaping () -> Void = {}) {
        self.commands = commands
        self.scopes = scopes
        recents = recentsKey.map { LumenCommandRecents(key: $0) }
        fixedRecents = nil
        isSnapshot = false
        self.onDismiss = onDismiss
        _query = State(initialValue: query)
    }

    /// Fixed recents and a highlight, for previews and snapshots.
    init(_ commands: [LumenCommand], scopes: [LumenPaletteScope] = [], query: String, recents: [String], highlighted: String?) {
        self.commands = commands
        self.scopes = scopes
        self.recents = nil
        fixedRecents = recents
        isSnapshot = true
        onDismiss = {}
        _query = State(initialValue: query)
        _highlighted = State(initialValue: highlighted)
    }

    private var placeholder: String { resolved.scope?.placeholder ?? (scopes.isEmpty ? "Search commands" : "Search") }

    private var resolved: (scope: LumenPaletteScope?, query: String) { LumenPaletteScope.resolve(query, in: scopes) }

    /// Rows matched once per query, scope, recents or command set, not once per body (PERF-02):
    /// highlight moves and hovers re-evaluate the body and must not re-match every command.
    @State private var cache = LumenCommandPaletteCache()

    private var rows: [(command: LumenCommand, offsets: [Int], isRecent: Bool)] {
        let (scope, text) = resolved
        return cache.rows(commands, scope: scope, query: text, recents: fixedRecents ?? recents?.ids ?? [])
    }

    private static func help(for scope: LumenPaletteScope) -> String {
        guard let prefix = scope.prefix else { return "Search everything" }
        return "Type \(String(prefix)) to search \(scope.title)"
    }

    /// Switches scope by rewriting the query's prefix, so typing and clicking agree.
    private func choose(_ scope: LumenPaletteScope) {
        let text = resolved.query
        query = scope.prefix.map { String($0) + text } ?? text
    }

    /// The palette's one content inset: the search glyph, scope titles, section labels, row tiles
    /// and footer keycaps all start here. Containers (the scope track, the row highlight) sit at
    /// `containerInset`, with their content at `contentInset` inside them.
    private var contentInset: CGFloat { metrics.spacing.s5 }
    private var containerInset: CGFloat { metrics.spacing.s2 }
    private var scopeRim: CGFloat { metrics.spacing.s1 }

    private var scopeBar: some View {
        let current = resolved.scope?.id
        return HStack(spacing: 2) {
            ForEach(scopes) { scope in
                let selected = scope.id == current
                Button { choose(scope) } label: {
                    HStack(spacing: metrics.spacing.s1) {
                        // A 24 pt one-line control: 13 pt text (§10).
                        Text(scope.title).font(metrics.typography.body)
                        if let prefix = scope.prefix { LumenKeycap([String(prefix)], onHighlight: selected) }
                    }
                    // A selected scope is a filled chip: the deep accent with white.
                    .foregroundStyle(palette[selected ? .accentFilledForeground : .menuSecondaryForeground])
                    .padding(.horizontal, contentInset - containerInset - scopeRim)
                    .frame(height: metrics.layout.controlHeight - scopeRim * 2)
                    .background(selected ? palette[.accentFilled] : .clear, in: .capsule)
                    .contentShape(.capsule)
                }
                .buttonStyle(.lumenBare)
                .focusable(false)
                .help(Self.help(for: scope))
                .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
            }
            Spacer(minLength: 0)
        }
        .padding(scopeRim)
        .background(palette[.bgInsetRaised].opacity(0.6), in: .capsule)
        .padding(.horizontal, containerInset)
        .padding(.bottom, metrics.spacing.s3)
    }

    /// Static content in place of the field and scroll view: in snapshots, and wherever an app
    /// renders offscreen (`.lumenRendersOffscreen()`).
    private var drawsStatic: Bool { isSnapshot || rendersOffscreen }

    public var body: some View {
        let rows = rows
        VStack(spacing: 0) {
            HStack(spacing: metrics.spacing.s3) {
                LumenSymbol("magnifyingglass").font(.system(size: metrics.iconSize.large, weight: .medium)).foregroundStyle(palette[.fgTertiary])
                if drawsStatic {
                    Text(query.isEmpty ? placeholder : query).font(metrics.typography.paletteQuery.weight(.regular))
                        .foregroundStyle(palette[query.isEmpty ? .fgTertiary : .menuForeground])
                    Spacer(minLength: 0)
                } else {
                TextField(placeholder, text: $query, prompt: Text(placeholder).foregroundStyle(palette[.fgTertiary]))
                    .textFieldStyle(.plain)
                    .font(metrics.typography.paletteQuery.weight(.regular))
                    .foregroundStyle(palette[.menuForeground])
                    .focused($searchFocused)
                    .onSubmit { run(rows.first { $0.command.id == highlighted }?.command) }
                    .onKeyPress(.downArrow) { move(1, in: rows); return .handled }
                    .onKeyPress(.upArrow) { move(-1, in: rows); return .handled }
                    .onExitCommand(perform: onDismiss)
                    .onChange(of: query) { highlighted = self.rows.first { $0.command.isEnabled }?.command.id }
                }
            }
            .padding(.horizontal, contentInset)
            .frame(height: metrics.layout.paletteQueryHeight)
            if !scopes.isEmpty { scopeBar }
            Rectangle().fill(palette[.menuSeparator]).frame(height: metrics.stroke.hairline)
            if rows.isEmpty {
                LumenEmptyState.inline(scopes.isEmpty ? "No matching commands" : "No matches", ink: .menuSecondaryForeground,
                                       padding: metrics.spacing.s8)
            } else if drawsStatic {
                results(rows)
            } else {
                ScrollViewReader { proxy in
                    ScrollView { results(rows) }
                        .frame(maxHeight: 380)
                        .fixedSize(horizontal: false, vertical: true)
                        .onChange(of: highlighted) { _, id in if let id { proxy.scrollTo(id) } }
                }
            }
            Rectangle().fill(palette[.menuSeparator]).frame(height: metrics.stroke.hairline)
            HStack(spacing: metrics.spacing.s4) {
                hint(["↑", "↓"], "move")
                hint(["↩"], "run")
                hint(["esc"], "close")
                Spacer()
            }
            .padding(.horizontal, contentInset)
            .frame(height: 30)
        }
        .frame(minWidth: 0, idealWidth: Self.width, maxWidth: Self.width)
        .lumenRaisedGround()
        .background(palette[.menuBackground], in: .rect(cornerRadius: metrics.radius.xl, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: metrics.radius.xl, style: .continuous).strokeBorder(palette[.borderDefault], lineWidth: metrics.stroke.hairline) }
        .lumenElevation(.popover)
        .onAppear {
            if highlighted == nil { highlighted = rows.first { $0.command.isEnabled }?.command.id }
        }
        .onChange(of: cache.rowsKey(commands)) {
            // Commands can change while the palette is open (a toggle's title, a disabled item).
            highlighted = Self.repairedHighlight(highlighted, in: rows)
        }
        .task {
            // Focus once the field is in the window; set on appear, another field can keep focus.
            searchFocused = true
            try? await Task.sleep(for: .milliseconds(60))
            searchFocused = true
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Command palette")
    }

    private func results(_ rows: [(command: LumenCommand, offsets: [Int], isRecent: Bool)]) -> some View {
        LumenCommandResultStack(isSnapshot: drawsStatic) {
            ForEach(Array(rows.enumerated()), id: \.element.command.id) { index, row in
                // One root per command lets the lazy container know row identities
                // without materializing every optional category header first.
                VStack(alignment: .leading, spacing: 0) {
                    if let header = header(for: index, in: rows) {
                        Text(header).lumenSectionLabel(.menuSecondaryForeground)
                            .padding(.horizontal, contentInset - containerInset)
                            .padding(.top, index == 0 ? metrics.spacing.s3 : metrics.spacing.s5)
                            .padding(.bottom, metrics.spacing.s2)
                    }
                    rowView(row).id(row.command.id)
                }
            }
        }
        .padding(.horizontal, containerInset)
        .padding(.bottom, metrics.spacing.s2)
    }

    private func header(for index: Int, in rows: [(command: LumenCommand, offsets: [Int], isRecent: Bool)]) -> String? {
        guard query.trimmingCharacters(in: .whitespaces).isEmpty else { return index == 0 ? "Results" : nil }
        let row = rows[index]
        let previous = index > 0 ? rows[index - 1] : nil
        if row.isRecent { return previous == nil ? "Recent" : nil }
        if previous?.isRecent ?? true { return row.command.category }
        return previous?.command.category == row.command.category ? nil : row.command.category
    }

    private func rowView(_ row: (command: LumenCommand, offsets: [Int], isRecent: Bool)) -> some View {
        let command = row.command
        let isHighlighted = command.id == highlighted
        let foreground = palette[isHighlighted ? .menuHighlightForeground : .menuForeground]
        return Button { run(command) } label: {
            HStack(spacing: metrics.spacing.s4) {
                // On the highlight the tile turns into the highlight's template plate, one look
                // for every hue.
                // A one-line row takes the menu tile, as the command menu does: the detailed tile
                // filled its row, so tiles touched. The column keeps the detailed tile's width,
                // so titles line up across one- and two-line rows.
                LumenRowTile(systemImage: command.systemImage, hue: command.hue,
                             size: command.subtitle == nil ? metrics.layout.tileMenu : metrics.layout.tileRowDetailed,
                             isHighlighted: isHighlighted)
                    .frame(width: metrics.layout.tileRowDetailed)
                VStack(alignment: .leading, spacing: metrics.spacing.s1) {
                    Text(title(command.title, offsets: row.offsets, highlighted: isHighlighted))
                        .font(metrics.typography.body).foregroundStyle(foreground).lineLimit(1)
                        .lumenNeverTruncates(command.title)
                    if let subtitle = command.subtitle {
                        // Text on the highlight is full white: dimmed white fell under 4.5:1.
                        Text(subtitle).font(metrics.typography.caption).lineLimit(1).truncationMode(.tail).help(subtitle)
                            .foregroundStyle(isHighlighted ? foreground : palette[.menuSecondaryForeground])
                    }
                }
                Spacer(minLength: metrics.spacing.s4)
                // The category only where no section header above already names it (recents), or
                // where it's what the query matched (no letters of the title are highlighted).
                let showsCategory = row.isRecent || (!query.isEmpty && row.offsets.isEmpty)
                if let trailing = command.detail ?? (showsCategory ? command.category : nil) {
                    // Details often name paths/categories: preserve the distinguishing final component.
                    // Subtitles read as prose and retain their beginning instead.
                    Text(trailing).font(metrics.typography.caption)
                        .lineLimit(1).truncationMode(.head).help(trailing)
                        .foregroundStyle(isHighlighted ? foreground : palette[.menuSecondaryForeground])
                }
                if let shortcut = command.shortcut { LumenKeycap(shortcut, onHighlight: isHighlighted) }
            }
            .padding(.horizontal, contentInset - containerInset)
            .frame(minHeight: command.subtitle == nil ? density.rowHeight(in: metrics.layout) : density.detailedRowHeight(in: metrics.layout))
            .background(palette[.menuHighlight].opacity(isHighlighted ? 1 : 0), in: .rect(cornerRadius: metrics.radius.md, style: .continuous))
            .opacity(command.isEnabled ? 1 : metrics.layout.disabledOpacity)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .focusable(false)
        .disabled(!command.isEnabled)
        .onHover { if $0 && command.isEnabled { highlighted = command.id } }
        .accessibilityLabel(command.title)
        .accessibilityHint(command.subtitle ?? command.category)
    }

    /// The title with the matched characters emphasized. On the highlight every letter is full
    /// white and matches stand out by weight alone, as Spotlight marks them (dimming the rest fell
    /// under 4.5:1).
    private func title(_ text: String, offsets: [Int], highlighted: Bool) -> AttributedString {
        var result = AttributedString()
        for (offset, character) in text.enumerated() {
            var piece = AttributedString(String(character))
            if offsets.contains(offset) {
                // Bold enough to read at a glance (calm type made the emphasized weight too quiet here).
                piece.font = metrics.typography.body.weight(.bold)
                if !highlighted { piece.foregroundColor = palette[.accent] }
            }
            result += piece
        }
        return result
    }

    private func hint(_ keys: [String], _ label: String) -> some View {
        HStack(spacing: metrics.spacing.s2) {
            LumenKeycap(keys)
            Text(label).font(metrics.typography.caption).foregroundStyle(palette[.menuSecondaryForeground])
        }
    }

    /// Everything about the commands that decides which rows show and which can be highlighted:
    /// a change to any of it (a renamed command leaving the results, say) rechecks the highlight.
    static func rowsKey(_ commands: [LumenCommand]) -> [String] {
        commands.map { command in
            ([command.id, command.isEnabled ? "1" : "0", command.title, command.category, command.scope ?? ""] + command.keywords)
                .joined(separator: "\u{1F}")
        }
    }

    /// The highlight, kept while its row still shows and is enabled; otherwise the first enabled row.
    static func repairedHighlight(_ highlighted: String?, in rows: [(command: LumenCommand, offsets: [Int], isRecent: Bool)]) -> String? {
        if rows.contains(where: { $0.command.id == highlighted && $0.command.isEnabled }) { return highlighted }
        return rows.first { $0.command.isEnabled }?.command.id
    }

    private func move(_ step: Int, in rows: [(command: LumenCommand, offsets: [Int], isRecent: Bool)]) {
        let ids = rows.filter(\.command.isEnabled).map(\.command.id)
        highlighted = LumenSelectionStep.next(ids, from: highlighted, by: step)
    }

    private func run(_ command: LumenCommand?) {
        guard let command, command.isEnabled else { return }
        recents?.record(command.id, among: commands.map(\.id))
        onDismiss()
        command.perform()
    }
}

/// Offscreen snapshots need eager layout; interactive palettes materialize only
/// the visible rows. The same content and command identities serve both paths.
/// The palette's matched rows and its commands' folded titles, kept between body evaluations
/// (PERF-02). Holding the commands it last saw means a new command set always arrives in new
/// storage, so the same storage is an exact "commands unchanged" test.
@MainActor final class LumenCommandPaletteCache {
    typealias Row = (command: LumenCommand, offsets: [Int], isRecent: Bool)
    private var commands: [LumenCommand] = []
    private var prepared: [String: LumenCommandMatcher.Prepared] = [:]
    private var key: (scope: String?, query: String, recents: [String])?
    private var cached: [Row] = []
    private var keyCommands: [LumenCommand]?
    private var cachedRowsKey: [String] = []
    /// How many times the matcher ran, for tests.
    private(set) var matchPasses = 0


    func rows(_ commands: [LumenCommand], scope: LumenPaletteScope?, query: String, recents: [String]) -> [Row] {
        let sameCommands = lumenSameStorage(commands, self.commands)
        if sameCommands, let key, key.scope == scope?.id, key.query == query, key.recents == recents { return cached }
        if !sameCommands {
            self.commands = commands
            prepared = [:]
        }
        let listed = scope.map { scope in commands.filter { scope.includes($0) } } ?? commands
        cached = LumenCommandMatcher.rows(listed, query: query, recents: recents) { command in
            if let known = prepared[command.id] { return known }
            let made = LumenCommandMatcher.Prepared(title: command.title, keywords: command.keywords + [command.category])
            prepared[command.id] = made
            return made
        }
        key = (scope?.id, query, recents)
        matchPasses += 1
        return cached
    }

    /// `LumenCommandPalette.rowsKey`, rebuilt only for a new command set.
    func rowsKey(_ commands: [LumenCommand]) -> [String] {
        if let keyCommands, lumenSameStorage(commands, keyCommands) { return cachedRowsKey }
        keyCommands = commands
        cachedRowsKey = LumenCommandPalette.rowsKey(commands)
        return cachedRowsKey
    }
}

struct LumenCommandResultStack<Content: View>: View {
    let isSnapshot: Bool
    let content: Content

    init(isSnapshot: Bool, @ViewBuilder content: () -> Content) {
        self.isSnapshot = isSnapshot
        self.content = content()
    }

    var body: some View {
        if isSnapshot {
            VStack(alignment: .leading, spacing: 0) { content }
        } else {
            LazyVStack(alignment: .leading, spacing: 0) { content }
        }
    }
}

// MARK: Presentation

public extension FocusedValues {
    @Entry var lumenCommandPalette: Binding<Bool>?
}

public extension View {
    /// Floats the command palette over this view, near the top, while `isPresented`. Clicking outside
    /// closes it. The window publishes it to `LumenViewCommands` (View › Command Palette…).
    ///
    /// - Parameter shortcut: the shortcut registered here, ⌘K by default. Pass `nil` when the app installs
    ///   `LumenViewCommands`, which owns it then, or opens the palette from its own menu item.
    func lumenCommandPalette(isPresented: Binding<Bool>, commands: [LumenCommand], recentsKey: String? = "lumen.commandPalette.recents",
                             query: String = "", shortcut: KeyboardShortcut? = LumenShortcuts.commandPalette) -> some View {
        modifier(LumenCommandPaletteHost(isPresented: isPresented, commands: commands, scopes: [], recentsKey: recentsKey, query: query,
                                         shortcut: shortcut))
    }

    /// The palette with scopes (Files /, Symbols #, Commands >): an Open Quickly. Open it with a
    /// prefix already typed (`query: "#"`) to start in a scope.
    func lumenCommandPalette(isPresented: Binding<Bool>, commands: [LumenCommand], scopes: [LumenPaletteScope],
                             recentsKey: String? = "lumen.commandPalette.recents", query: String = "",
                             shortcut: KeyboardShortcut? = LumenShortcuts.commandPalette) -> some View {
        modifier(LumenCommandPaletteHost(isPresented: isPresented, commands: commands, scopes: scopes, recentsKey: recentsKey, query: query,
                                         shortcut: shortcut))
    }
}

/// The window a palette opened in, and when closing it may take focus back from a field.
@MainActor final class LumenPalettePresenter {
    weak var window: NSWindow?

    /// The control a responder is editing: a text field's, through its field editor; otherwise the
    /// responder itself.
    static func editedControl(_ responder: NSResponder?) -> NSResponder? {
        if let editor = responder as? NSTextView, editor.isFieldEditor, let field = editor.delegate as? NSResponder { return field }
        return responder
    }

    /// Clear focus after closing only in the palette's window while it's still key, and only when
    /// focus has since moved into a text field (SwiftUI's fallback when the search field went away),
    /// not when it stayed where a command put it.
    static func shouldClearFocus(in window: NSWindow, keyWindow: NSWindow?, editingAtClose: NSResponder?) -> Bool {
        guard keyWindow === window else { return false }
        let now = editedControl(window.firstResponder)
        guard let field = now as? NSTextField, field.window === window else { return false }
        return field !== editingAtClose
    }
}

private struct LumenCommandPaletteHost: ViewModifier {
    @Binding var isPresented: Bool
    let commands: [LumenCommand]
    let scopes: [LumenPaletteScope]
    let recentsKey: String?
    let query: String
    let shortcut: KeyboardShortcut?

    @Environment(\.lumenMetrics) private var metrics
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.lumenMenuOwnsShortcuts) private var menuOwnsShortcuts
    /// The window the palette opened in (weakly).
    @State private var presenter = LumenPalettePresenter()

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if isPresented {
                    ZStack(alignment: .top) {
                        Color.black.opacity(0.08).contentShape(.rect).onTapGesture { isPresented = false }
                        LumenCommandPalette(commands, scopes: scopes, query: query, recentsKey: recentsKey) { isPresented = false }
                            .padding(.top, 64)
                            // In a narrow window the palette narrows, keeping a margin on both sides.
                            .padding(.horizontal, metrics.spacing.s8)
                    }
                    .transition(.opacity)
                }
            }
            .animation(metrics.motion.animation(metrics.motion.fastCurve, reduceMotion: reduceMotion), value: isPresented)
            .onChange(of: isPresented) { _, presented in
                guard !presented else {
                    presenter.window = NSApp.keyWindow
                    return
                }
                // Closing removes the focused search field; don't let focus fall into some other text
                // field (a sidebar filter, say). The window takes it, as before the palette opened.
                // Only in the palette's own window, while it's still key, and only when focus fell into
                // a field after closing: a command that opened a window or focused its editor keeps it.
                guard let window = presenter.window ?? NSApp.keyWindow else { return }
                let editingAtClose = LumenPalettePresenter.editedControl(window.firstResponder)
                Task { @MainActor [weak window] in
                    try? await Task.sleep(for: .milliseconds(30))
                    guard let window, LumenPalettePresenter.shouldClearFocus(in: window, keyWindow: NSApp.keyWindow,
                                                                             editingAtClose: editingAtClose) else { return }
                    window.makeFirstResponder(nil)
                }
            }
            .background {
                if isPresented {
                    // Escape closes the palette wherever focus is.
                    Button("Close Command Palette") { isPresented = false }
                        .keyboardShortcut(.cancelAction)
                        .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
                }
                if let shortcut, !menuOwnsShortcuts {
                    Button("Command Palette") { isPresented.toggle() }
                        .keyboardShortcut(shortcut)
                        .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
                }
            }
            .focusedSceneValue(\.lumenCommandPalette, $isPresented)
    }
}

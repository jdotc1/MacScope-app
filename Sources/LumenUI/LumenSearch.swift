import AppKit
import SwiftUI
import LumenTokens

// Finding things: text with its matches marked, search results grouped by
// file, the find and replace panel, and an input palette for Go To Line.

// MARK: Highlighted text

/// How matched text stands out.
public enum LumenMatchStyle: Sendable, Hashable {
    /// A soft violet marker (`accent.subtle`) behind the match, as code editors' find draws one,
    /// underlined in the accent so it shows on every ground,
    /// including light sidebars where the tint is nearly white. Leaves the text's own colors alone,
    /// so it reads in code.
    case marker
    /// Bold, in the accent, as the command palette marks matched letters.
    case emphasis
}

/// Text with matched ranges marked: a marker behind each (search results) or bold accent (titles).
/// Ranges are character offsets; ones out of bounds are ignored.
public struct LumenHighlightedText: View {
    private let text: String
    private let ranges: [Range<Int>]
    private let style: LumenMatchStyle

    @Environment(\.lumenPalette) private var palette

    public init(_ text: String, ranges: [Range<Int>], style: LumenMatchStyle = .marker) {
        self.text = text
        self.ranges = ranges
        self.style = style
    }

    /// Marks every case-insensitive occurrence of `query`.
    public init(_ text: String, matching query: String, style: LumenMatchStyle = .marker) {
        self.init(text, ranges: Self.ranges(of: query, in: text), style: style)
    }

    /// Character ranges of each case- and diacritic-insensitive occurrence of `query` in `text`.
    static func ranges(of query: String, in text: String) -> [Range<Int>] {
        guard !query.isEmpty else { return [] }
        var result: [Range<Int>] = []
        var searchStart = text.startIndex
        while let found = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], range: searchStart..<text.endIndex) {
            let lower = text.distance(from: text.startIndex, to: found.lowerBound)
            result.append(lower..<(lower + text.distance(from: found.lowerBound, to: found.upperBound)))
            searchStart = found.isEmpty ? text.index(after: found.lowerBound) : found.upperBound
            if searchStart >= text.endIndex { break }
        }
        return result
    }

    public var body: some View {
        Text(attributed)
    }

    var attributed: AttributedString {
        var result = AttributedString(text)
        let count = text.count
        for range in ranges where range.lowerBound >= 0 && range.upperBound <= count && !range.isEmpty {
            let start = result.index(result.startIndex, offsetByCharacters: range.lowerBound)
            let end = result.index(result.startIndex, offsetByCharacters: range.upperBound)
            switch style {
            case .marker:
                // The tint alone vanished on the light sidebar (GB-07); the accent underline carries it there.
                result[start..<end].backgroundColor = palette[.accentSubtle]
                result[start..<end].underlineStyle = Text.LineStyle(pattern: .solid, color: palette[.accent])
            case .emphasis:
                result[start..<end].foregroundColor = palette[.accent]
                result[start..<end].inlinePresentationIntent = .stronglyEmphasized
            }
        }
        return result
    }
}

// MARK: Search results

/// One matching line.
public struct LumenSearchMatch: Identifiable, Hashable, Sendable {
    public let id: String
    public let line: Int
    /// The line's text, trimmed as it should show.
    public let text: String
    /// The match within `text`, as character offsets.
    public let ranges: [Range<Int>]

    public init(id: String? = nil, line: Int, text: String, ranges: [Range<Int>]) {
        self.id = id ?? "\(line):\(ranges.first?.lowerBound ?? 0)"
        self.line = line
        self.text = text
        self.ranges = ranges
    }
}

/// A file's matches.
public struct LumenSearchFile: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    /// Where it is, for the help tag.
    public let path: String?
    public let systemImage: String
    public let hue: LumenToken
    public let matches: [LumenSearchMatch]

    public init(id: String, name: String, path: String? = nil, systemImage: String = "doc.text", hue: LumenToken = .fgSecondary,
                matches: [LumenSearchMatch]) {
        self.id = id
        self.name = name
        self.path = path
        self.systemImage = systemImage
        self.hue = hue
        self.matches = matches
    }
}

/// Search results grouped by file: a summary ("58 results in 12 files") with
/// expand and collapse all, then each file under a disclosure with its count, and its matching lines
/// with the match marked. Click a line to open it there.
public struct LumenSearchResults: View {
    private let files: [LumenSearchFile]
    @Binding private var collapsed: Set<String>
    private let onOpen: (LumenSearchFile, LumenSearchMatch) -> Void

    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenDensity) private var density
    @Environment(\.lumenMetrics) private var metrics
    @Environment(\.lumenCodeFont) private var codeFont
    @State private var hovered: String?
    @Environment(\.lumenEmptyMessage) private var emptyMessage

    /// - Parameter collapsed: ids of collapsed files.
    public init(_ files: [LumenSearchFile], collapsed: Binding<Set<String>>,
                onOpen: @escaping (LumenSearchFile, LumenSearchMatch) -> Void) {
        self.files = files
        _collapsed = collapsed
        self.onOpen = onOpen
    }

    /// "58 results in 12 files", "1 result in 1 file", or "No results".
    static func summary(_ files: [LumenSearchFile]) -> String {
        let results = files.reduce(0) { $0 + $1.matches.count }
        guard results > 0 else { return "No results" }
        let count = files.filter { !$0.matches.isEmpty }.count
        return "\(results.formatted()) \(results == 1 ? "result" : "results") in \(count.formatted()) \(count == 1 ? "file" : "files")"
    }

    public var body: some View {
        // Filtered and counted once a body (PERF-07: the body did each three times).
        let shown = files.filter { !$0.matches.isEmpty }
        let summary = Self.summary(files)
        VStack(alignment: .leading, spacing: 0) {
            header(summary)
            if shown.isEmpty {
                LumenEmptyState.inline(emptyMessage ?? "Nothing matches the search")
            }
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(shown) { file in
                    fileRow(file)
                    if !collapsed.contains(file.id) {
                        ForEach(file.matches) { match in matchRow(match, in: file) }
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Search results, " + summary)
    }

    private func header(_ summary: String) -> some View {
        HStack(spacing: metrics.spacing.s2) {
            Button("Expand All", systemImage: "arrow.up.left.and.arrow.down.right") { collapsed = [] }
                .labelStyle(.iconOnly).buttonStyle(.lumenPanelIcon).help("Expand All")
                .lumenIconOnlyControl("Expand All")
            Button("Collapse All", systemImage: "arrow.down.right.and.arrow.up.left") { collapsed = Set(files.map(\.id)) }
                .labelStyle(.iconOnly).buttonStyle(.lumenPanelIcon).help("Collapse All")
                .lumenIconOnlyControl("Collapse All")
            Spacer(minLength: metrics.spacing.s2)
            // Trailing-aligned, opposite the buttons: a count anchored to an edge, not floating mid-bar.
            Text(summary).font(metrics.typography.caption).foregroundStyle(palette[.fgSecondary]).lineLimit(1).truncationMode(.tail).help(summary)
        }
        .font(.system(size: metrics.iconSize.xsmall))
        .padding(.horizontal, Self.inset(metrics))
        .frame(height: metrics.layout.subheaderHeight)
    }

    /// The results' side inset, shared with `LumenFindPanel` so a find panel stacked over its results
    /// keeps one leading and one trailing edge.
    static func inset(_ metrics: LumenMetrics) -> CGFloat { metrics.spacing.s3 }

    /// How many characters of context a match line keeps before its first match.
    static let leadingContext = 12

    /// The match line as it shows: when the first match starts far in, the leading context is
    /// trimmed to "…" plus `leadingContext` characters, so the tail truncation never hides the match
    /// itself. Ranges shift with the text.
    static func displayed(_ match: LumenSearchMatch) -> (text: String, ranges: [Range<Int>]) {
        guard let first = match.ranges.map(\.lowerBound).min(), first > leadingContext + 1 else {
            return (match.text, match.ranges)
        }
        // Cut at a token boundary: never "…blic struct", but "…struct".
        let characters = Array(match.text)
        var cut = first - leadingContext
        while cut < first, characters[cut - 1].isLetter || characters[cut - 1].isNumber || characters[cut - 1] == "_" { cut += 1 }
        while cut < first, characters[cut].isWhitespace { cut += 1 }
        let text = "…" + String(characters[cut...])
        let ranges = match.ranges.map { ($0.lowerBound - cut + 1)..<($0.upperBound - cut + 1) }
        return (text, ranges)
    }

    private func fileRow(_ file: LumenSearchFile) -> some View {
        let open = !collapsed.contains(file.id)
        return Button {
            if open { collapsed.insert(file.id) } else { collapsed.remove(file.id) }
        } label: {
            HStack(spacing: metrics.spacing.s2) {
                LumenSymbol("chevron.right").font(.system(size: metrics.layout.disclosureGlyph, weight: .bold)).foregroundStyle(palette[.fgTertiary])
                    .rotationEffect(.degrees(open ? 90 : 0))
                // A fixed icon column, so every file name starts at one edge whatever its glyph's width.
                LumenSymbol(file.systemImage).foregroundStyle(palette[file.hue])
                    .frame(width: metrics.iconSize.large, alignment: .center)
                Text(file.name).font(metrics.typography.captionEmphasized).foregroundStyle(palette[.fgPrimary]).lineLimit(1)
                    .truncationMode(.middle)
                LumenCount(file.matches.count)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Self.inset(metrics))
            .frame(height: density.rowHeight(in: metrics.layout))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(file.path ?? file.name)
        .accessibilityLabel("\(file.name), \(file.matches.count) matches")
        .accessibilityValue(open ? "Expanded" : "Collapsed")
    }

    private func matchRow(_ match: LumenSearchMatch, in file: LumenSearchFile) -> some View {
        let key = file.id + "#" + match.id
        return Button { onOpen(file, match) } label: {
            HStack(alignment: .firstTextBaseline, spacing: metrics.spacing.s2) {
                Text(verbatim: String(match.line))
                    .font((codeFont ?? .standard).font(sizeDelta: -2))
                    .foregroundStyle(palette[.fgTertiary])
                    .frame(minWidth: 28, alignment: .trailing)
                let shown = Self.displayed(match)
                LumenSemanticText(shown.text, kind: .snippet, lineLimit: 2, originalValue: match.text,
                                  requiredRange: shown.ranges.first, renderChunk: { chunk, offset in
                    var attributed = AttributedString(chunk)
                    for range in shown.ranges {
                        let lower = max(0, range.lowerBound - offset)
                        let upper = min(chunk.count, range.upperBound - offset)
                        guard lower < upper else { continue }
                        let start = attributed.index(attributed.startIndex, offsetByCharacters: lower)
                        let end = attributed.index(attributed.startIndex, offsetByCharacters: upper)
                        attributed[start..<end].backgroundColor = palette[.accentSubtle]
                        attributed[start..<end].underlineStyle = Text.LineStyle(pattern: .solid, color: palette[.accent])
                    }
                    return Text(attributed)
                })
                    .font((codeFont ?? .standard).font(sizeDelta: -1))
                    .foregroundStyle(palette[.fgSecondary])
                Spacer(minLength: 0)
            }
            .padding(.leading, metrics.spacing.s4)
            .padding(.trailing, Self.inset(metrics))
            .frame(minHeight: density.rowHeight(in: metrics.layout))
            .background(hovered == key ? palette[.bgHover].opacity(palette.key.raised ? 1 : metrics.layout.hoverOpacity) : .clear, in: .rect(cornerRadius: metrics.radius.sm))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 ? key : (hovered == key ? nil : hovered) }
        .help("\(file.name):\(match.line)")
        .accessibilityLabel("Line \(match.line): \(match.text)")
    }
}

// MARK: Find panel

/// How a search pattern matches.
public enum LumenFindMode: String, CaseIterable, Identifiable, Sendable {
    case contains = "Contains", startsWith = "Starts With", wholeWord = "Whole Word", regex = "Regular Expression"
    public var id: String { rawValue }
}

/// What the find panel searches for, as one value an app observes.
public struct LumenFindQuery: Hashable, Sendable {
    public var pattern: String
    public var replacement: String
    public var mode: LumenFindMode
    public var caseSensitive: Bool

    public init(pattern: String = "", replacement: String = "", mode: LumenFindMode = .contains, caseSensitive: Bool = false) {
        self.pattern = pattern
        self.replacement = replacement
        self.mode = mode
        self.caseSensitive = caseSensitive
    }
}

/// Find and replace, for a sidebar: a scope menu, the pattern with its match mode and a
/// case toggle, the replacement, and Replace All beside an accent Find. Return in the pattern finds.
public struct LumenFindPanel<Scope: Hashable>: View {
    @Binding private var query: LumenFindQuery
    @Binding private var scope: Scope
    private let scopes: [Scope]
    private let scopeTitle: (Scope) -> String
    private let onFind: () -> Void
    private let onReplaceAll: (() -> Void)?
    private let drawsStatic: Bool

    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenMetrics) private var metrics
    @Environment(\.lumenRendersOffscreen) private var rendersOffscreen
    @FocusState private var patternFocused: Bool
    @FocusState private var replacementFocused: Bool

    /// - Parameter onReplaceAll: `nil` hides the replacement row.
    public init(query: Binding<LumenFindQuery>, scope: Binding<Scope>, scopes: [Scope], scopeTitle: @escaping (Scope) -> String,
                onFind: @escaping () -> Void, onReplaceAll: (() -> Void)? = nil) {
        self.init(query: query, scope: scope, scopes: scopes, scopeTitle: scopeTitle, drawsStatic: false, onFind: onFind,
                  onReplaceAll: onReplaceAll)
    }

    /// For golden images, where text fields and menus can't draw.
    init(query: Binding<LumenFindQuery>, scope: Binding<Scope>, scopes: [Scope], scopeTitle: @escaping (Scope) -> String,
         drawsStatic: Bool, onFind: @escaping () -> Void, onReplaceAll: (() -> Void)?) {
        _query = query
        _scope = scope
        self.scopes = scopes
        self.scopeTitle = scopeTitle
        self.onFind = onFind
        self.onReplaceAll = onReplaceAll
        self.drawsStatic = drawsStatic
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: metrics.spacing.s2) {
            menu(scopeTitle(scope), options: scopes, title: scopeTitle) { scope = $0 }
            field($query.pattern, prompt: "Find", symbol: "magnifyingglass", focus: $patternFocused, submit: onFind)
            HStack(spacing: metrics.spacing.s2) {
                menu(query.mode.rawValue, options: LumenFindMode.allCases, title: \.rawValue) { query.mode = $0 }
                Spacer(minLength: 0)
                Button { query.caseSensitive.toggle() } label: {
                    Text("Aa").font(metrics.typography.caption.weight(.semibold))
                        .foregroundStyle(palette[query.caseSensitive ? .accent : .fgSecondary])
                        .frame(minWidth: metrics.layout.minimumHitTarget, minHeight: metrics.layout.controlHeight)
                        .background(query.caseSensitive ? palette[.accentSubtle] : .clear, in: .rect(cornerRadius: metrics.radius.sm))
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .lumenIconOnlyControl("Case sensitive")
                .help(query.caseSensitive ? "Case sensitive" : "Ignore case")
                .accessibilityLabel("Case sensitive")
                .accessibilityValue(query.caseSensitive ? "On" : "Off")
            }
            if let onReplaceAll {
                field($query.replacement, prompt: "Replace", symbol: "arrow.2.squarepath", focus: $replacementFocused, submit: {})
                HStack(spacing: metrics.spacing.s2) {
                    Spacer(minLength: 0)
                    Button("Replace All", action: onReplaceAll).buttonStyle(.lumenQuiet).disabled(query.pattern.isEmpty).fixedSize()
                    Button("Find", action: onFind).buttonStyle(.lumenPrimary).disabled(query.pattern.isEmpty).fixedSize()
                }
            } else {
                HStack { Spacer(minLength: 0); Button("Find", action: onFind).buttonStyle(.lumenPrimary).disabled(query.pattern.isEmpty).fixedSize() }
            }
        }
        .padding(.horizontal, LumenSearchResults.inset(metrics))
        .padding(.vertical, metrics.spacing.s3)
    }

    /// Static text in place of the fields: in golden images, and wherever an app renders offscreen.
    private var isStatic: Bool { drawsStatic || rendersOffscreen }

    /// Find and Replace share one field: Lumen's field chrome at the one-line control height, the
    /// glyph in a fixed column so both texts start at one edge.
    private func field(_ text: Binding<String>, prompt: String, symbol: String, focus: FocusState<Bool>.Binding,
                       submit: @escaping () -> Void) -> some View {
        HStack(spacing: metrics.spacing.s2) {
            LumenSymbol(symbol).font(.system(size: metrics.iconSize.xsmall)).foregroundStyle(palette[.fgTertiary])
                .frame(width: metrics.iconSize.small)
            LumenFieldInput(text: text, prompt: prompt, focus: focus, onSubmit: submit)
                .environment(\.lumenRendersOffscreen, isStatic)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !text.wrappedValue.isEmpty {
                // A full hit area; the glyph stays at the field's inset.
                Button("Clear", systemImage: "xmark.circle.fill") { text.wrappedValue = "" }
                    .labelStyle(.iconOnly).buttonStyle(.plain).foregroundStyle(palette[.fgTertiary])
                    .frame(width: metrics.layout.minimumHitTarget, height: metrics.layout.controlHeight)
                    .contentShape(.rect)
                    .lumenIconOnlyControl("Clear")
                    .padding(.trailing, -(metrics.layout.minimumHitTarget - metrics.iconSize.small) / 2)
                    .help("Clear")
            }
        }
        .font(metrics.typography.body)
        .padding(.horizontal, metrics.spacing.s3)
        .frame(height: metrics.layout.controlHeight)
        .lumenChrome(.field, focused: focus.wrappedValue)
    }

    @ViewBuilder
    private func menu<Option: Hashable>(_ current: String, options: [Option], title: @escaping (Option) -> String,
                                        choose: @escaping (Option) -> Void) -> some View {
        let label = HStack(spacing: metrics.spacing.s1) {
            Text(current).font(metrics.typography.caption.weight(.medium))
            LumenSymbol("chevron.up.chevron.down").font(.system(size: metrics.layout.disclosureGlyph, weight: .bold))
        }
        .foregroundStyle(palette[.fgSecondary])
        LumenMenuButton {
            ForEach(options, id: \.self) { option in Button(title(option)) { choose(option) } }
        } label: { label }
    }
}

// MARK: Go To Line

/// "12" or "12:30" as a line and column, or `nil` for anything else (zero, negatives, letters).
public enum LumenGoToLine {
    public static func parse(_ text: String) -> (line: Int, column: Int?)? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), let line = Int(parts[0]), line > 0 else { return nil }
        guard parts.count == 2 else { return (line, nil) }
        guard let column = Int(parts[1]), column > 0 else { return nil }
        return (line, column)
    }
}

/// The palette's shell asking for one value: a tile, the field in large type and
/// a line of help. Return submits when `isValid` passes; Escape closes.
public struct LumenInputPalette: View {
    private let systemImage: String
    private let hue: LumenToken
    private let placeholder: String
    private let help: String?
    private let isValid: (String) -> Bool
    private let onSubmit: (String) -> Void
    private let onDismiss: () -> Void
    private let drawsStatic: Bool

    @State private var text: String
    @FocusState private var focused: Bool
    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenMetrics) private var metrics
    @Environment(\.lumenRendersOffscreen) private var rendersOffscreen

    public init(_ placeholder: String, systemImage: String, hue: LumenToken = .accent, help: String? = nil,
                isValid: @escaping (String) -> Bool = { !$0.isEmpty }, onSubmit: @escaping (String) -> Void,
                onDismiss: @escaping () -> Void = {}) {
        self.init(placeholder, systemImage: systemImage, hue: hue, help: help, text: "", drawsStatic: false, isValid: isValid,
                  onSubmit: onSubmit, onDismiss: onDismiss)
    }

    init(_ placeholder: String, systemImage: String, hue: LumenToken, help: String?, text: String, drawsStatic: Bool,
         isValid: @escaping (String) -> Bool, onSubmit: @escaping (String) -> Void, onDismiss: @escaping () -> Void) {
        self.systemImage = systemImage
        self.hue = hue
        self.placeholder = placeholder
        self.help = help
        self.isValid = isValid
        self.onSubmit = onSubmit
        self.onDismiss = onDismiss
        self.drawsStatic = drawsStatic
        _text = State(initialValue: text)
    }

    public var body: some View {
        let invalid = !text.isEmpty && !isValid(text)
        VStack(alignment: .leading, spacing: metrics.spacing.s2) {
            HStack(spacing: metrics.spacing.s4) {
                LumenIconTile(systemImage, hue: hue, size: metrics.layout.tileProminent)
                if drawsStatic || rendersOffscreen {
                    Text(text.isEmpty ? placeholder : text).font(metrics.typography.paletteQuery)
                        .foregroundStyle(palette[text.isEmpty ? .fgTertiary : .menuForeground])
                    Spacer(minLength: 0)
                } else {
                    TextField(placeholder, text: $text, prompt: Text(placeholder).foregroundStyle(palette[.fgTertiary]))
                        .textFieldStyle(.plain)
                        .font(metrics.typography.paletteQuery)
                        .foregroundStyle(palette[invalid ? .statusDanger : .menuForeground])
                        .focused($focused)
                        .onSubmit { if isValid(text) { onSubmit(text); onDismiss() } }
                        .onExitCommand(perform: onDismiss)
                }
            }
            .frame(minHeight: metrics.layout.paletteQueryHeight)
            if let help {
                Text(help).font(metrics.typography.caption).foregroundStyle(palette[invalid ? .statusDanger : .menuSecondaryForeground])
                    .lumenWrapsWithoutTruncating()
            }
        }
        .padding(metrics.spacing.s5)
        // The widest it gets; in a narrower window it narrows to fit (the host keeps a margin).
        .frame(minWidth: 0, idealWidth: 520, maxWidth: 520, alignment: .leading)
        .lumenRaisedGround()
        .background(palette[.menuBackground], in: .rect(cornerRadius: metrics.radius.xl, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: metrics.radius.xl, style: .continuous).strokeBorder(palette[.borderDefault], lineWidth: metrics.stroke.hairline) }
        .lumenElevation(.popover)
        .task {
            focused = true
            try? await Task.sleep(for: .milliseconds(60))
            focused = true
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(placeholder)
    }
}

public extension View {
    /// Floats an input palette near the top while `isPresented` (Go To Line, say). Clicking outside or
    /// Escape closes it.
    func lumenInputPalette(isPresented: Binding<Bool>, placeholder: String, systemImage: String, hue: LumenToken = .accent,
                           help: String? = nil, isValid: @escaping (String) -> Bool = { !$0.isEmpty },
                           onSubmit: @escaping (String) -> Void) -> some View {
        overlay(alignment: .top) {
            if isPresented.wrappedValue {
                ZStack(alignment: .top) {
                    Color.black.opacity(0.08).contentShape(.rect).onTapGesture { isPresented.wrappedValue = false }
                    LumenInputPalette(placeholder, systemImage: systemImage, hue: hue, help: help, isValid: isValid, onSubmit: onSubmit) {
                        isPresented.wrappedValue = false
                    }
                    .padding(.top, 64)
                    .padding(.horizontal, LumenMetrics.standard.spacing.s8)
                }
                .transition(.opacity)
            }
        }
    }

    /// Go To Line: "12" or "12:30", handed back parsed.
    func lumenGoToLine(isPresented: Binding<Bool>, onGo: @escaping (_ line: Int, _ column: Int?) -> Void) -> some View {
        lumenInputPalette(isPresented: isPresented, placeholder: "Go to Line", systemImage: "number", hue: .hueGraphite,
                          help: "Enter a line number (“12”) or a line and column (“12:30”).",
                          isValid: { LumenGoToLine.parse($0) != nil }) { text in
            if let target = LumenGoToLine.parse(text) { onGo(target.line, target.column) }
        }
    }
}

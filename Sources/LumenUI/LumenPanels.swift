import AppKit
import SwiftUI
import LumenTokens

// Panel and navigation pieces from the workspace window: capsule tabs whose icons take their hue when
// selected, filter fields and chips, a log console over a native table, a sidebar switcher and
// sections, document tabs and a status bar of compact menus.

// MARK: Panel tabs

/// One tab in a panel's tab strip.
public struct LumenPanelTab: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let systemImage: String
    public let hue: LumenToken

    public init(id: String, title: String, systemImage: String, hue: LumenToken = .accent) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.hue = hue
    }
}

/// A panel's tab strip: the selected tab sits on a soft accent fill and its icon takes its hue;
/// the others stay quiet until hovered.
public struct LumenPanelTabs: View {
    /// Which tabs show their titles: all, or only the selected one (for many tabs in a narrow
    /// panel; the others show their icon, with the title in the help tag).
    public enum Labels: Sendable { case all, selectedOnly }

    @Binding private var selection: String
    private let tabs: [LumenPanelTab]
    private let labels: Labels

    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenMetrics) private var metrics
    @State private var hovered: String?
    @FocusState private var focused: Bool

    public init(selection: Binding<String>, tabs: [LumenPanelTab], labels: Labels = .all) {
        _selection = selection
        self.tabs = tabs
        self.labels = labels
    }

    public var body: some View {
        // Adapts to its column (PRINCIPLES §6, tab strips never push the layout wider): every title
        // when they fit, then only the selected tab's, then a strip that scrolls.
        ViewThatFits(in: .horizontal) {
            if labels == .all { strip(.all).fixedSize(horizontal: true, vertical: false) }
            strip(.selectedOnly).fixedSize(horizontal: true, vertical: false)
            ScrollView(.horizontal, showsIndicators: false) { strip(.selectedOnly) }
                .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        }
        .lumenSelectionGroup(tabs.map(\.id), selection: $selection, focused: $focused)
        .accessibilityElement(children: .contain)
    }

    private func strip(_ labels: Labels) -> some View {
        HStack(spacing: metrics.spacing.s1) {
            ForEach(tabs) { tab in
                let selected = tab.id == selection
                Button { selection = tab.id } label: {
                    HStack(spacing: metrics.spacing.s2) {
                        LumenSymbol(tab.systemImage).foregroundStyle(palette[selected ? tab.hue : .fgTertiary])
                        if labels == .all || selected {
                            Text(tab.title).font(metrics.typography.body).foregroundStyle(palette[selected ? .fgPrimary : .fgSecondary])
                                .lineLimit(1).lumenNeverTruncates(tab.title)
                        }
                    }
                    .font(metrics.typography.body)
                    .padding(.horizontal, metrics.spacing.s3)
                    .frame(height: metrics.layout.controlHeight)
                    // Panel tabs are modes: the selected one sits on a plate (the selection family
                    // for modes and tools), as the sidebar switcher's selected tile does.
                    .background {
                        let shape = RoundedRectangle(cornerRadius: metrics.radius.sm, style: .continuous)
                        if selected {
                            shape.fill(palette[.bgElevated])
                                .overlay { shape.strokeBorder(palette[.borderDefault], lineWidth: metrics.stroke.hairline) }
                        } else {
                            shape.fill(palette[.bgHover]).opacity(hovered == tab.id ? metrics.layout.hoverOpacity : 0)
                        }
                    }
                    .lumenGroupFocusRing(focused && selected, cornerRadius: metrics.radius.sm)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .focusable(false)
                .onHover { hovered = $0 ? tab.id : (hovered == tab.id ? nil : hovered) }
                .help(tab.title)
                .accessibilityLabel(tab.title)
                .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
            }
        }
    }
}

// MARK: Filter field and chips

/// A capsule filter field on `field.background`, with the filter symbol lit while it filters and a
/// clear button once there's text.
public struct LumenFilterField: View {
    @Binding private var text: String
    private let prompt: String
    private let takesInitialFocus: Bool

    @FocusState private var isFocused: Bool
    @State private var handedBackInitialFocus = false
    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenMetrics) private var metrics

    /// - Parameter takesInitialFocus: whether the field may keep the focus a new window gives its first
    ///   text field. Off by default: a sidebar filter shouldn't capture typing meant for the content.
    public init(text: Binding<String>, prompt: String = "Filter", takesInitialFocus: Bool = false) {
        _text = text
        self.prompt = prompt
        self.takesInitialFocus = takesInitialFocus
    }

    public var body: some View {
        HStack(spacing: metrics.spacing.s2) {
            LumenSymbol("line.3.horizontal.decrease.circle")
                .foregroundStyle(palette[text.isEmpty ? .fgTertiary : .accent])
                .accessibilityHidden(true)
            TextField(prompt, text: $text, prompt: Text(prompt).foregroundStyle(palette[.fgTertiary]))
                .textFieldStyle(.plain)
                .focused($isFocused)
                .foregroundStyle(palette[.fgPrimary])
                // Escape clears the filter, then leaves the field, as native search fields do.
                .onExitCommand { if text.isEmpty { isFocused = false } else { text = "" } }
            if !text.isEmpty {
                Button("Clear Filter", systemImage: "xmark.circle.fill") { text = "" }
                    .labelStyle(.iconOnly)
                    .lumenIconOnlyControl("Clear Filter")
                    .buttonStyle(.lumenPlain).lumenFocusRing()
                    .foregroundStyle(palette[.fgTertiary])
                    .frame(width: metrics.layout.minimumHitTarget, height: metrics.layout.minimumHitTarget)
                    .contentShape(.rect)
                    .help("Clear Filter")
            }
        }
        .font(metrics.typography.body)
        .padding(.horizontal, metrics.spacing.s3)
        .frame(height: metrics.layout.controlHeight)
        .background(palette[.fieldBackground], in: .capsule)
        .overlay { Capsule(style: .circular).strokeBorder(palette[.borderFocus].opacity(isFocused ? 0.8 : 0), lineWidth: metrics.stroke.regular) }
        // AppKit gives a new window's first text field the focus. Hand it back unless asked to keep
        // it: on the first focus change (that initial grant), not after a guessed delay.
        // A click or Tab into the field is never that grant, even when it's the first focus.
        .onChange(of: isFocused) { _, focused in
            if focused, !takesInitialFocus, !handedBackInitialFocus, text.isEmpty,
               !Self.isDeliberateFocus(NSApp.currentEvent.map { ($0.type, $0.window) }, keyWindow: NSApp.keyWindow) {
                isFocused = false
            }
            handedBackInitialFocus = true
        }
    }

    /// Whether the event behind a focus change is the person moving focus: a click or key press in
    /// the key window. AppKit's initial grant comes with no event, or with the one that opened the
    /// window (a menu click, ⌘N), which belongs to another window.
    static func isDeliberateFocus(_ event: (type: NSEvent.EventType, window: NSWindow?)?, keyWindow: NSWindow?) -> Bool {
        guard let event, let window = event.window, window === keyWindow else { return false }
        return [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown].contains(event.type)
    }
}

/// A row of filter chips, one selected: the selection fills with `chip.selectedBackground`, as
/// The console level filter does.
public struct LumenFilterChips<Value: Hashable>: View {
    @Binding private var selection: Value
    private let options: [Value]
    private let groups: [[Value]]
    private let title: (Value) -> String
    private let count: ((Value) -> Int?)?

    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenMetrics) private var metrics
    @State private var hovered: Value?
    @FocusState private var focused: Bool

    public init(selection: Binding<Value>, options: [Value], title: @escaping (Value) -> String) {
        self.init(selection: selection, groups: [options], title: title, count: nil)
    }

    /// Chips in groups split by hairlines, each with an optional count (the key bindings scope bar:
    /// All | Menu, Extensions | Customized, Conflicts (2)).
    public init(selection: Binding<Value>, groups: [[Value]], title: @escaping (Value) -> String, count: ((Value) -> Int?)? = nil) {
        _selection = selection
        self.groups = groups
        options = groups.flatMap(\.self)
        self.title = title
        self.count = count
    }

    /// "Conflicts (2)", or the title alone without a count.
    static func label(_ title: String, count: Int?) -> String { count.map { "\(title) (\($0))" } ?? title }

    public var body: some View {
        HStack(spacing: metrics.spacing.s1) {
            ForEach(Array(groups.enumerated()), id: \.offset) { index, group in
                if index > 0 {
                    LumenInlineDivider()
                        .padding(.horizontal, metrics.spacing.s1)
                }
                chips(group)
            }
        }
        .lumenSelectionGroup(options, selection: $selection, focused: $focused)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private func chips(_ group: [Value]) -> some View {
            ForEach(group, id: \.self) { option in
                let selected = option == selection
                Button { selection = option } label: {
                    Text(Self.label(title(option), count: count?(option)))
                        .font(metrics.typography.body.weight(selected ? .semibold : .medium))   // 13 pt in a 24 pt control; only the selection is strong
                        .lineLimit(1)
                        .lumenNeverTruncates(Self.label(title(option), count: count?(option)))
                        .fixedSize()
                        .foregroundStyle(palette[selected ? .chipSelectedForeground : .fgSecondary])
                        .padding(.horizontal, metrics.spacing.s3)
                        .frame(height: metrics.layout.minimumHitTarget)
                        .background(selected ? palette[.chipSelectedBackground] : hovered == option ? palette.hoverFill(metrics) : .clear,
                                    in: .rect(cornerRadius: metrics.radius.sm, style: .continuous))
                        .lumenGroupFocusRing(focused && selected, cornerRadius: metrics.radius.sm)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .focusable(false)
                .onHover { hovered = $0 ? option : (hovered == option ? nil : hovered) }
                .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
            }
    }
}

/// A small tinted button for panel actions such as Clear: fg.primary on the soft accent fill.
public struct LumenTintedButtonStyle: ButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View { TintedLabel(configuration: configuration) }

    private struct TintedLabel: View {
        let configuration: Configuration
        @Environment(\.lumenPalette) private var palette
        @Environment(\.lumenMetrics) private var metrics
        @Environment(\.isEnabled) private var isEnabled
        var body: some View {
            configuration.label
                .font(metrics.typography.body.weight(.semibold))
                .foregroundStyle(palette[.fgPrimary])
                .padding(.horizontal, metrics.spacing.s3)
                .frame(height: metrics.layout.controlHeight)
                .background(palette[configuration.isPressed ? .bgSelected : .accentSubtle],
                            in: .rect(cornerRadius: metrics.radius.sm, style: .continuous))
                .lumenDisabledFade(isEnabled)
        }
    }
}

// MARK: Log console

/// One line in a log console.
public struct LumenLogEntry: Identifiable, Hashable, Sendable {
    public enum Level: String, CaseIterable, Sendable { case log, warning, error }

    public let id: UUID
    public let date: Date
    public let source: String
    public let level: Level
    public let message: String

    public init(id: UUID = UUID(), date: Date, source: String, level: Level = .log, message: String) {
        self.id = id
        self.date = date
        self.source = source
        self.level = level
        self.message = message
    }
}

/// Which levels a log console shows.
public enum LumenLogFilter: String, CaseIterable, Hashable, Sendable {
    case all, errors, warnings, logs

    public var title: String { rawValue.capitalized }

    func admits(_ level: LumenLogEntry.Level) -> Bool {
        switch self {
        case .all: true
        case .errors: level == .error
        case .warnings: level == .warning
        case .logs: level == .log
        }
    }
}

/// A log console, for an extension's output: a source menu, a filter field, level chips and
/// Clear above a native table (column resizing, selection, copy) of time, source and message in
/// monospace. Errors and warnings carry their status color.
public struct LumenLogConsole: View {
    private let entries: [LumenLogEntry]
    private let onClear: (() -> Void)?

    @State private var source: String?
    @State private var query = ""
    @State private var selectedLines = Set<LumenLogEntry.ID>()
    @State private var filter: LumenLogFilter
    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenMetrics) private var metrics
    @Environment(\.lumenCodeFont) private var codeFont

    @Environment(\.lumenEmptyMessage) private var emptyMessage

    public init(_ entries: [LumenLogEntry], filter: LumenLogFilter = .all, onClear: (() -> Void)? = nil) {
        self.entries = entries
        self.onClear = onClear
        _filter = State(initialValue: filter)
    }

    /// Filtered lines and sources, worked out once per change of entries or filter (PERF-01).
    @State private var cache = LumenLogConsoleCache()

    var sources: [String] { cache.sources(for: entries) }

    var shown: [LumenLogEntry] { cache.shown(entries, filter: filter, source: source, query: query) }

    /// The person's code font a point smaller, else the metrics' monospaced caption.
    private var mono: Font { codeFont?.font(sizeDelta: -1) ?? metrics.typography.monoCaption }

    public var body: some View {
        let shown = shown
        VStack(spacing: 0) {
            LumenLogFilterBar(sources: sources, source: $source, query: $query, filter: $filter, onClear: onClear)
                .onChange(of: sources) { _, sources in
                    // A source that's gone (after Clear, say) would leave the menu blank and hide new lines.
                    if let source, !sources.contains(source) { self.source = nil }
                }
            Rectangle().fill(palette[.borderSubtle]).frame(height: metrics.stroke.hairline)
            ScrollViewReader { proxy in
            Table(shown, selection: $selectedLines) {
                TableColumn("Time") { entry in
                    Text(entry.date, format: LumenLogConsole.timeFormat)
                        .font(mono).foregroundStyle(palette[.fgTertiary])
                }
                .width(min: 96, ideal: 110, max: 130)
                TableColumn("Source") { entry in
                    Text(entry.source).font(mono).foregroundStyle(palette[.fgSecondary]).lineLimit(1).truncationMode(.middle).help(entry.source)
                }
                .width(min: 70, ideal: 130, max: 170)
                TableColumn("Message") { entry in
                    HStack(alignment: .firstTextBaseline, spacing: metrics.spacing.s2) {
                        switch entry.level {
                        case .error: LumenSymbol("xmark.octagon.fill").foregroundStyle(palette[.statusDanger])
                        case .warning: LumenSymbol("exclamationmark.triangle.fill").foregroundStyle(palette[.statusWarning])
                        case .log: EmptyView()
                        }
                        Text(entry.message).font(mono)
                            .foregroundStyle(palette[entry.level == .error ? .statusDanger : .fgPrimary])
                            .textSelection(.enabled)
                    }
                }
            }
            .tableStyle(.inset(alternatesRowBackgrounds: false))
            .scrollContentBackground(.hidden)
            // A filter change that adds or removes thousands of rows builds a fresh table rather than
            // diffing them away (PERF-01: narrowing 100k lines to a few hundred took SwiftUI's diff
            // over 10 s; building the few hundred takes well under one). Column widths the person
            // dragged return to their defaults then.
            .id(cache.generation)
            .background(palette[.bgCanvas])
            .overlay(alignment: .top) {
                // Over the table, so the console keeps its size: nothing logged, or a filter that hides it all.
                if shown.isEmpty {
                    LumenEmptyState.inline(emptyMessage ?? (entries.isEmpty ? "Nothing logged yet" : "No entries match the filter"),
                                           padding: metrics.spacing.s8)
                }
            }
            // Follows new lines as they arrive, like Console, unless a line is selected to read.
            .onChange(of: shown.last?.id) { _, last in
                guard selectedLines.isEmpty, let last else { return }
                proxy.scrollTo(last, anchor: .bottom)
            }
            }
        }
    }

    /// 14:36:39.290, 24-hour in every locale (a 12-hour clock without AM/PM would be ambiguous).
    static let timeFormat = Date.VerbatimFormatStyle(
        format: "\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits):\(second: .twoDigits).\(secondFraction: .fractional(3))",
        timeZone: .current, calendar: Calendar(identifier: .gregorian))
}

/// The log console's filtered lines and source list, kept between body evaluations (PERF-01): at
/// 100k entries one filter pass costs hundreds of milliseconds, and the body reads both several
/// times per keystroke and per new line. Holding the entries it last saw means an app's change to
/// its array always copies it, so an unchanged buffer is an exact "nothing changed" test; appended
/// lines (the console's common case) are filtered on their own.
@MainActor final class LumenLogConsoleCache {
    /// Bumped when a filter change adds or removes more rows than SwiftUI's table diffs quickly;
    /// the console gives its table this identity, so such a change builds a fresh table instead.
    private(set) var generation = 0
    static let rebuildThreshold = 1_000
    private var seen: [LumenLogEntry] = []
    private var key: (filter: LumenLogFilter, source: String?, query: String)?
    private var filtered: [LumenLogEntry] = []
    private var sourcesSeen: [LumenLogEntry] = []
    private var sourceSet = Set<String>()
    private var sortedSources: [String] = []
    /// How many full filter passes ran, for tests.
    private(set) var fullPasses = 0

    static func admits(_ entry: LumenLogEntry, filter: LumenLogFilter, source: String?, query: String) -> Bool {
        filter.admits(entry.level)
            && (source == nil || entry.source == source)
            && (query.isEmpty || entry.message.localizedCaseInsensitiveContains(query) || entry.source.localizedCaseInsensitiveContains(query))
    }


    /// `new` is `old` with lines added at the end (same first and last-old line).
    private static func appended(_ new: [LumenLogEntry], to old: [LumenLogEntry]) -> Bool {
        guard let first = old.first, let last = old.last, new.count > old.count else { return false }
        return new[0].id == first.id && new[old.count - 1].id == last.id
    }

    func shown(_ entries: [LumenLogEntry], filter: LumenLogFilter, source: String?, query: String) -> [LumenLogEntry] {
        let sameKey = key.map { $0.filter == filter && $0.source == source && $0.query == query } ?? false
        if sameKey && lumenSameStorage(entries, seen) { return filtered }
        if sameKey && Self.appended(entries, to: seen) {
            filtered += entries[seen.count...].filter { Self.admits($0, filter: filter, source: source, query: query) }
        } else {
            let before = filtered.count
            filtered = entries.filter { Self.admits($0, filter: filter, source: source, query: query) }
            fullPasses += 1
            if abs(filtered.count - before) > Self.rebuildThreshold { generation += 1 }
        }
        seen = entries
        key = (filter, source, query)
        return filtered
    }

    func sources(for entries: [LumenLogEntry]) -> [String] {
        if lumenSameStorage(entries, sourcesSeen) { return sortedSources }
        let set = Self.appended(entries, to: sourcesSeen)
            ? sourceSet.union(entries[sourcesSeen.count...].map(\.source))
            : Set(entries.map(\.source))
        if set != sourceSet || sourcesSeen.isEmpty { sortedSources = set.sorted() }
        sourceSet = set
        sourcesSeen = entries
        return sortedSources
    }
}

/// The console's filter bar, separate so it can be used over any log view.
public struct LumenLogFilterBar: View {
    private let sources: [String]
    @Binding private var source: String?
    @Binding private var query: String
    @Binding private var filter: LumenLogFilter
    private let onClear: (() -> Void)?

    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenMetrics) private var metrics

    public init(sources: [String], source: Binding<String?>, query: Binding<String>, filter: Binding<LumenLogFilter>,
                onClear: (() -> Void)? = nil) {
        self.sources = sources
        _source = source
        _query = query
        _filter = filter
        self.onClear = onClear
    }

    public var body: some View {
        // Narrow panels get the same controls in less room: the level chips become a menu, then the
        // filter field shrinks. Nothing is ever cut off.
        ViewThatFits(in: .horizontal) {
            bar(chips: true)
            bar(chips: false)
        }
        .padding(.horizontal, metrics.spacing.s4)
        .padding(.vertical, metrics.spacing.s2)
    }

    private func bar(chips: Bool) -> some View {
        HStack(spacing: metrics.spacing.s4) {
            // Lumen's pop-up, as every other pop-up in a Lumen pane.
            LumenPopUp(selection: $source, options: [nil] + sources.map { Optional($0) }, title: { $0 ?? "All Sources" })
                .accessibilityLabel("Source")
            Spacer(minLength: chips ? metrics.spacing.s4 : 0)
            LumenFilterField(text: $query).frame(minWidth: chips ? 120 : 60, maxWidth: 260)
            if chips {
                LumenFilterChips(selection: $filter, options: LumenLogFilter.allCases, title: \.title)
            } else {
                LumenPopUp(selection: $filter, options: LumenLogFilter.allCases, title: \.title)
                    .accessibilityLabel("Level")
            }
            if let onClear {
                // An action, not a sixth level: a plain button set apart from the chips by a hairline.
                LumenInlineDivider()
                Button("Clear", action: onClear).buttonStyle(.lumenQuiet).lumenFocusRing().fixedSize()
            }
        }
    }
}

// MARK: Sidebar switcher and sections

/// One pane a sidebar switcher selects.
public struct LumenSidebarItem: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let systemImage: String
    public let hue: LumenToken?
    /// Set on the pane's button, for UI tests.
    public var accessibilityIdentifier: String?

    /// - Parameter hue: the selected icon's color; `nil` uses `sidebar.accent`.
    public init(id: String, title: String, systemImage: String, hue: LumenToken? = nil) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.hue = hue
    }

    /// - Parameter accessibilityIdentifier: set on the pane's button, for UI tests.
    public init(id: String, title: String, systemImage: String, hue: LumenToken? = nil, accessibilityIdentifier: String?) {
        self.init(id: id, title: title, systemImage: systemImage, hue: hue)
        self.accessibilityIdentifier = accessibilityIdentifier
    }
}

/// The row of pane icons at the top of a sidebar (files, search, source control…), the selected one
/// lit. ⌘1…⌘9 select panes, as in a navigator sidebar.
/// How a sidebar switcher draws its panes.
public enum LumenSidebarSwitcherStyle: Sendable {
    /// Glyphs, the current one on a quiet `sidebar.rowSelected` fill in its hue.
    case fill
    /// Each pane's glyph in a colored tile, the current one raised on a card, as the mode switcher
    /// draws modes.
    case tiles
}

public struct LumenSidebarSwitcher: View {
    @Binding private var selection: String
    private let items: [LumenSidebarItem]
    private let shortcuts: Bool
    private let arrangement: Binding<String>?
    private let style: LumenSidebarSwitcherStyle

    @Environment(\.lumenRendersOffscreen) private var rendersOffscreen
    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenMetrics) private var metrics
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.lumenMenuOwnsShortcuts) private var menuOwnsShortcuts
    @State private var hovered: String?
    @FocusState private var focused: Bool

    /// - Parameters:
    ///   - shortcuts: ⌘1…⌘9 for the visible panes, in order (none when the menu owns them:
    ///     `.lumenMenuOwnsShortcuts()` with `.lumenPaneCommands`).
    ///   - arrangement: the person's order and hidden panes, as `LumenToolLayout.encoded` (store it
    ///     with `@AppStorage`). With it, each pane's context menu moves it left or right, hides it, shows
    ///     all and resets; without it the panes are fixed.
    public init(selection: Binding<String>, items: [LumenSidebarItem], shortcuts: Bool = true, arrangement: Binding<String>? = nil) {
        self.init(selection: selection, items: items, shortcuts: shortcuts, arrangement: arrangement, style: .fill)
    }

    /// - Parameter style: `.tiles` draws each pane in its hue's tile (`item.hue`, else the accent).
    public init(selection: Binding<String>, items: [LumenSidebarItem], shortcuts: Bool = true, arrangement: Binding<String>? = nil,
                style: LumenSidebarSwitcherStyle) {
        _selection = selection
        self.items = items
        self.shortcuts = shortcuts
        self.arrangement = arrangement
        self.style = style
    }

    private var layout: LumenToolLayout {
        LumenToolLayout(encoded: arrangement?.wrappedValue ?? "", all: items.map(\.id))
    }

    private var visibleItems: [LumenSidebarItem] {
        let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return layout.visible.compactMap { byID[$0] }
    }

    public var body: some View {
        let shown = visibleItems
        HStack(spacing: 0) {
            ForEach(Array(shown.enumerated()), id: \.element.id) { index, item in
                let selected = item.id == selection
                Button { selection = item.id } label: {
                    paneLabel(item, selected: selected)
                        .frame(maxWidth: .infinity, minHeight: 28)
                        .lumenGroupFocusRing(focused && selected, cornerRadius: metrics.radius.sm)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .focusable(false)
                .onHover { hovered = $0 ? item.id : (hovered == item.id ? nil : hovered) }
                .keyboardShortcut(shortcuts && !menuOwnsShortcuts ? LumenShortcuts.pane(index + 1) : nil)
                .help(item.title + (shortcuts && index < 9 ? " (⌘\(index + 1))" : ""))
                .accessibilityLabel(item.title)
                .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
                .lumenAccessibilityIdentifier(item.accessibilityIdentifier)
                .contextMenu { if arrangement != nil { arrangementMenu(for: item) } }
                .modifier(PaneDropTarget(enabled: arrangement != nil && !rendersOffscreen) { id in update { $0.dock(id, before: item.id) } })
            }
        }
        .modifier(PaneDropTarget(enabled: arrangement != nil && !rendersOffscreen) { id in update { $0.dock(id, before: nil) } })
        .lumenSelectionGroup(shown.map(\.id), selection: $selection, focused: $focused)
        .lumenTileBacklight(style == .tiles)
        .lumenBacklightContainer("Sidebar switcher")
        // Tiles: the first plate starts at the sidebar's leading edge, where the hairline and the
        // section tiles below start, so the column has one leading edge.
        .padding(.horizontal, style == .tiles ? 0 : metrics.spacing.s2)
        // Centered in the space above the hairline (the plate sat 1 pt low); tiles leave room
        // under them for their contained backlight, which ends before the hairline.
        .padding(.bottom, metrics.stroke.hairline)
        .frame(height: style == .tiles ? max(metrics.layout.subheaderHeight, metrics.layout.tileTool + metrics.spacing.s4) : metrics.layout.subheaderHeight)
        .overlay(alignment: .bottom) { Rectangle().fill(palette[.borderSubtle]).frame(height: metrics.stroke.hairline) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sidebar panes")
    }

    @ViewBuilder
    private func paneLabel(_ item: LumenSidebarItem, selected: Bool) -> some View {
        switch style {
        case .fill:
            LumenSymbol(item.systemImage)
                .font(.system(size: metrics.iconSize.regular, weight: selected ? .semibold : .regular))
                .foregroundStyle(palette[selected ? (item.hue ?? .sidebarAccent)
                                         : hovered == item.id ? .sidebarForeground : .sidebarSecondaryForeground])
                .frame(maxWidth: .infinity, minHeight: 28)
                // The selected pane also gets a shape, not only a color.
                .background(palette[.sidebarRowSelected].opacity(selected ? 0.8 : 0),
                            in: .rect(cornerRadius: metrics.radius.sm, style: .continuous))
        case .tiles:
            // Full color whether selected or not: the plate behind marks the selection. Fading or
            // graying unselected tiles made them read as smaller and disabled.
            LumenIconTile(item.systemImage, hue: item.hue ?? .accent, size: metrics.layout.tileTool)
                .lumenIconRole(.control)
                .frame(maxWidth: .infinity, minHeight: metrics.layout.tileTool + 6)
                .background {
                    if selected {
                        RoundedRectangle(cornerRadius: metrics.radius.sm, style: .continuous)
                            .fill(palette[.bgElevated])
                            .overlay {
                                RoundedRectangle(cornerRadius: metrics.radius.sm, style: .continuous)
                                    .strokeBorder(palette[.borderDefault], lineWidth: metrics.stroke.hairline)
                            }
                    }
                }
        }
    }

    @ViewBuilder
    private func arrangementMenu(for item: LumenSidebarItem) -> some View {
        let layout = layout
        Button("Move Left") { update { $0.move(item.id, by: -1) } }.disabled(!layout.canMove(item.id, by: -1))
        Button("Move Right") { update { $0.move(item.id, by: 1) } }.disabled(!layout.canMove(item.id, by: 1))
        Divider()
        // The pane on screen and the last visible pane can't be hidden.
        Button("Hide \(item.title)") { update { _ = $0.hide(item.id) } }
            .disabled(item.id == selection || layout.visible.count <= 1)
        Button("Show All") { update { $0.showAll() } }.disabled(layout.hidden.isEmpty)
        Button("Reset Order") { update { $0.reset() } }.disabled(layout.isDefault)
    }

    private func update(_ change: (inout LumenToolLayout) -> Void) {
        var next = layout
        change(&next)
        withAnimation(metrics.motion.animation(metrics.motion.fastCurve, reduceMotion: reduceMotion)) {
            arrangement?.wrappedValue = next.encoded
        }
    }
}

/// The person's arrangement of a row of tools or panes: their order and which are hidden. It stores as
/// one string (`"symbols,-search,files"`: hidden ones marked `-`, empty for the default), which an app
/// keeps in `@AppStorage`. Tools added later appear at the end; unknown ones are dropped; at least one
/// tool stays visible.
public struct LumenToolLayout: Hashable, Sendable {
    public private(set) var order: [String]
    public private(set) var hidden: Set<String>
    private let defaultOrder: [String]

    public init(all: [String]) {
        order = all
        hidden = []
        defaultOrder = all
    }

    public init(encoded: String, all: [String]) {
        self.init(all: all)
        var seen = Set<String>()
        var parsedOrder: [String] = []
        var parsedHidden = Set<String>()
        for entry in encoded.split(separator: ",") {
            let isHidden = entry.hasPrefix("-")
            let id = String(isHidden ? entry.dropFirst() : entry[...])
            guard all.contains(id), seen.insert(id).inserted else { continue }
            parsedOrder.append(id)
            if isHidden { parsedHidden.insert(id) }
        }
        order = parsedOrder + all.filter { !seen.contains($0) }
        hidden = parsedHidden
        if visible.isEmpty { hidden.removeAll() }
    }

    public var visible: [String] { order.filter { !hidden.contains($0) } }
    public var isDefault: Bool { order == defaultOrder && hidden.isEmpty }

    /// The stored form; empty for the default arrangement.
    public var encoded: String {
        isDefault ? "" : order.map { hidden.contains($0) ? "-" + $0 : $0 }.joined(separator: ",")
    }

    /// Whether `id` can move `offset` places among the visible tools.
    public func canMove(_ id: String, by offset: Int) -> Bool {
        guard let index = visible.firstIndex(of: id) else { return false }
        return visible.indices.contains(index + offset)
    }

    /// Moves `id` past the visible tool `offset` places away; hidden tools keep their relative place.
    public mutating func move(_ id: String, by offset: Int) {
        guard offset != 0, canMove(id, by: offset), let from = visible.firstIndex(of: id) else { return }
        let neighbor = visible[from + offset]
        order.removeAll { $0 == id }
        guard let anchor = order.firstIndex(of: neighbor) else { return }
        order.insert(id, at: offset > 0 ? anchor + 1 : anchor)
    }

    /// Hides `id`, refusing to hide the last visible tool. Returns whether it was hidden.
    @discardableResult
    public mutating func hide(_ id: String) -> Bool {
        guard !hidden.contains(id), visible.count > 1 else { return false }
        hidden.insert(id)
        return true
    }

    public mutating func showAll() { hidden.removeAll() }

    /// Shows `id` where it was.
    public mutating func show(_ id: String) { hidden.remove(id) }

    /// Shows `id` and moves it before the visible tool `before` (to the end for `nil`): a pane dropped
    /// on the dock.
    public mutating func dock(_ id: String, before: String?) {
        guard order.contains(id), id != before else { return }
        hidden.remove(id)
        order.removeAll { $0 == id }
        if let before, let anchor = order.firstIndex(of: before) {
            order.insert(id, at: anchor)
        } else {
            order.append(id)
        }
    }

    public mutating func reset() {
        order = defaultOrder
        hidden.removeAll()
    }
}

/// A sidebar section with a count (MacScope's Binaries, Functions): its glyph in a tile, its title and
/// count, then its rows, or, while the count is zero, one quiet line saying what will appear there
/// (no "No items" placeholder rows).
public struct LumenSidebarCountSection<Content: View>: View {
    private let title: String
    private let systemImage: String
    private let hue: LumenToken
    private let count: Int
    private let emptyMessage: String
    private let content: Content

    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenMetrics) private var metrics

    public init(_ title: String, systemImage: String, hue: LumenToken, count: Int, emptyMessage: String,
                @ViewBuilder content: () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.hue = hue
        self.count = count
        self.emptyMessage = emptyMessage
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: metrics.spacing.s2) {
            HStack(spacing: metrics.spacing.s3) {
                LumenIconTile(systemImage, hue: hue, size: metrics.layout.tileSection)
                    .lumenIconRole(.section)
                Text(title).font(metrics.typography.headline).foregroundStyle(palette[.sidebarForeground]).lineLimit(1)
                    .lumenNeverTruncates(title)
                Spacer(minLength: metrics.spacing.s2)
                LumenCount(count)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            if count == 0 {
                // The inline empty state, leading at the title's inset; the section's own spacing pads it,
                // less the 2 pt the callout line adds over the old caption, so the section keeps its height.
                LumenEmptyState.inline(emptyMessage, leading: true, padding: 0)
                    .padding(.leading, metrics.layout.tileSection + metrics.spacing.s3)
                    .padding(.top, -metrics.spacing.s1)
            } else {
                content
            }
        }
        .padding(.vertical, metrics.spacing.s2)
    }
}

/// A sidebar section: a bold title with optional accessory buttons over a hairline, then its content
/// (rows, or an empty state).
public struct LumenSidebarSection<Accessory: View, Content: View>: View {
    private let title: String
    private let accessory: Accessory
    private let content: Content

    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenMetrics) private var metrics

    public init(_ title: String, @ViewBuilder accessory: () -> Accessory, @ViewBuilder content: () -> Content) {
        self.title = title
        self.accessory = accessory()
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: metrics.spacing.s2) {
                // The one group-label style.
                Text(title).lumenSectionLabel(.sidebarSecondaryForeground)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                accessory
                    // Native borderless buttons draw the system focus ring; Lumen can't wrap an app's
                    // buttons with its own. `actions:` draws Lumen's, with full-size targets.
                    .buttonStyle(.borderless)
                    .labelStyle(.iconOnly)
                    .foregroundStyle(palette[.sidebarSecondaryForeground])
            }
            .padding(.horizontal, metrics.spacing.s4)
            .frame(height: metrics.layout.subheaderHeight)
            .overlay(alignment: .bottom) {
                // Full width, as the switcher's hairline above it (§8: bands run the pane's full width).
                Rectangle().fill(palette[.borderSubtle]).frame(height: metrics.stroke.hairline)
            }
            content.frame(maxWidth: .infinity)
        }
    }
}

/// A button in a sidebar section's header, for `LumenSidebarSection(_:actions:content:)`.
public struct LumenSidebarAction: Identifiable {
    public let id: String
    public let title: String
    public let systemImage: String
    public let perform: () -> Void

    public init(_ title: String, systemImage: String, perform: @escaping () -> Void) {
        id = title
        self.title = title
        self.systemImage = systemImage
        self.perform = perform
    }
}

/// The header buttons Lumen draws for `actions:`: 24 pt targets with focus rings and help tags.
public struct LumenSidebarActions: View {
    let actions: [LumenSidebarAction]
    public var body: some View {
        HStack(spacing: 0) {
            ForEach(actions) { action in
                // LumenSymbol, so glyph names (lumen.…) draw as well as SF Symbols.
                Button(action: action.perform) { LumenSymbol(action.systemImage) }
                    .buttonStyle(.lumenPlain)
                    .lumenIconOnlyControl(action.title)
                    .accessibilityLabel(action.title)
                    .lumenFocusRing()
                    .help(action.title)
            }
        }
    }
}

public extension LumenSidebarSection where Accessory == LumenSidebarActions {
    /// A section whose header buttons Lumen draws: full-size targets, focus rings and help tags.
    init(_ title: String, actions: [LumenSidebarAction], @ViewBuilder content: () -> Content) {
        self.init(title, accessory: { LumenSidebarActions(actions: actions) }, content: content)
    }
}

public extension LumenSidebarSection where Accessory == EmptyView {
    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.init(title, accessory: { EmptyView() }, content: content)
    }
}

// MARK: Document tabs

/// One open document.
public struct LumenDocumentTab: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let systemImage: String
    public let hue: LumenToken
    /// A preview tab, replaced by the next file you open: shown in italics.
    public let isPreview: Bool
    /// Unsaved changes: a dot where the close button appears on hover.
    public let isEdited: Bool
    /// Pinned: kept at the front with a pin before its icon, and spared by Close Others and Close All.
    public var isPinned: Bool = false
    /// The tab's accent line, for a kind of tab that should read apart (a terminal in teal); `nil`
    /// uses `tab.accentBar`.
    public var accent: LumenToken?
    /// The file's path, for Copy Path in the tab's menu.
    public var path: String?

    public init(id: String, title: String, systemImage: String, hue: LumenToken = .fgSecondary, isPreview: Bool = false, isEdited: Bool = false) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.hue = hue
        self.isPreview = isPreview
        self.isEdited = isEdited
    }

    public init(id: String, title: String, systemImage: String, hue: LumenToken = .fgSecondary, isPreview: Bool = false, isEdited: Bool = false,
                isPinned: Bool, accent: LumenToken? = nil, path: String? = nil) {
        self.init(id: id, title: title, systemImage: systemImage, hue: hue, isPreview: isPreview, isEdited: isEdited)
        self.isPinned = isPinned
        self.accent = accent
        self.path = path
    }
}

/// What a document tab's context menu and drag-and-drop can do. Each action left `nil` is left out
/// of the menu.
public struct LumenTabActions {
    public var closeOthers: ((LumenDocumentTab) -> Void)?
    public var closeAll: (() -> Void)?
    public var togglePin: ((LumenDocumentTab) -> Void)?
    /// Opens a copy of the tab in a new split at that edge.
    public var duplicateInSplit: ((LumenDocumentTab, LumenSplitEdge) -> Void)?
    /// A tab (by id) was dropped on this bar, to go before the tab at that index (the end for `count`).
    public var dropTab: ((String, Int) -> Void)?
    /// `dropTab` with the pane the tab was dragged from, when its bar named one
    /// (`lumenTabDragPane`); used instead of `dropTab` when set.
    var moveTab: ((String, String?, Int) -> Void)?

    public init(closeOthers: ((LumenDocumentTab) -> Void)? = nil, closeAll: (() -> Void)? = nil,
                togglePin: ((LumenDocumentTab) -> Void)? = nil, duplicateInSplit: ((LumenDocumentTab, LumenSplitEdge) -> Void)? = nil,
                dropTab: ((String, Int) -> Void)? = nil) {
        self.closeOthers = closeOthers
        self.closeAll = closeAll
        self.togglePin = togglePin
        self.duplicateInSplit = duplicateInSplit
        self.dropTab = dropTab
    }
}

/// Where a new split opens beside the current pane.
public enum LumenSplitEdge: Sendable, Hashable, CaseIterable {
    case leading, trailing

    var title: String { self == .leading ? "Duplicate Tab in Split On Left" : "Duplicate Tab in Split On Right" }
}

extension EnvironmentValues {
    /// Whether the pane holding this tab bar has focus: unfocused panes' active tabs go quiet.
    @Entry var lumenPaneIsFocused = true
    /// The split-editor pane holding this tab bar: its dragged tabs carry it, so a drop takes the tab
    /// from that pane even when the same tab is open in another.
    @Entry var lumenTabDragPane: String?
}

/// Dragged tabs carry their id with this prefix, so other text drops are ignored.
let lumenTabDragPrefix = "lumen.tab:"
/// Separates a dragged tab's id from the pane it came from.
private let lumenTabDragPaneSeparator: Character = "\u{1F}"

/// A dragged tab's payload: the prefix, its id and, from a split-editor pane, that pane.
func lumenTabDragPayload(_ tabID: String, pane: String?) -> String {
    lumenTabDragPrefix + tabID + (pane.map { String(lumenTabDragPaneSeparator) + $0 } ?? "")
}

/// The tab id and source pane in a dropped payload; `nil` for anything that isn't a dragged tab.
func lumenTabDragContents(_ payload: String) -> (tabID: String, pane: String?)? {
    guard payload.hasPrefix(lumenTabDragPrefix) else { return nil }
    let body = payload.dropFirst(lumenTabDragPrefix.count)
    guard let separator = body.lastIndex(of: lumenTabDragPaneSeparator) else { return (String(body), nil) }
    return (String(body[..<separator]), String(body[body.index(after: separator)...]))
}

/// Where dragged tabs can be dropped, left off where it can't render (golden images) and when the bar
/// takes no drops.
private struct TabDropTarget: ViewModifier {
    let enabled: Bool
    let drop: ([String]) -> Bool

    func body(content: Content) -> some View {
        if enabled {
            content.dropDestination(for: String.self) { items, _ in drop(items) }
        } else {
            content
        }
    }
}

/// Dragged sidebar panes carry their id with this prefix.
let lumenPaneDragPrefix = "lumen.pane:"

/// Where a dragged sidebar pane can be dropped (the dock), left off offscreen.
struct PaneDropTarget: ViewModifier {
    let enabled: Bool
    let apply: (String) -> Void

    func body(content: Content) -> some View {
        if enabled {
            content.dropDestination(for: String.self) { items, _ in
                guard let item = items.first, item.hasPrefix(lumenPaneDragPrefix) else { return false }
                apply(String(item.dropFirst(lumenPaneDragPrefix.count)))
                return true
            }
        } else {
            content
        }
    }
}

/// A tab's drag source and context menu, left off where they can't render (golden images).
private struct TabInteractions<Menu: View>: ViewModifier {
    let tab: LumenDocumentTab
    let menu: Menu
    let enabled: Bool
    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenMetrics) private var metrics
    @Environment(\.lumenTabDragPane) private var dragPane

    func body(content: Content) -> some View {
        if enabled {
            content
                .draggable(lumenTabDragPayload(tab.id, pane: dragPane)) {
                    Label(tab.title, systemImage: "doc").padding(metrics.spacing.s3).background(palette[.bgElevated], in: .rect(cornerRadius: metrics.radius.sm))
                }
                .contextMenu { menu }
        } else {
            content
        }
    }
}

/// A document tab bar: the active tab carries `tab.accentBar` along its top edge on
/// `tab.activeFill`; each tab shows its file type in color.
public struct LumenDocumentTabBar: View {
    private let tabs: [LumenDocumentTab]
    @Binding private var selection: String?
    private let onClose: ((LumenDocumentTab) -> Void)?
    private let actions: LumenTabActions

    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenMetrics) private var metrics
    @Environment(\.lumenRendersOffscreen) private var rendersOffscreen
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focused: Bool
    @State private var contentFrame: CGRect = .zero
    @State private var viewportWidth: CGFloat = 0

    nonisolated private static var scrollSpace: String { "lumen.documentTabs" }

    public init(_ tabs: [LumenDocumentTab], selection: Binding<String?>, onClose: ((LumenDocumentTab) -> Void)? = nil) {
        self.init(tabs, selection: selection, onClose: onClose, actions: LumenTabActions())
    }

    /// - Parameter actions: the tab menu's actions and where dropped tabs go. Pinned tabs always
    ///   come first.
    public init(_ tabs: [LumenDocumentTab], selection: Binding<String?>, onClose: ((LumenDocumentTab) -> Void)? = nil,
                actions: LumenTabActions) {
        self.tabs = tabs.filter(\.isPinned) + tabs.filter { !$0.isPinned }
        _selection = selection
        self.onClose = onClose
        self.actions = actions
    }

    public var body: some View {
        // Tabs keep their width; when they don't all fit, the row scrolls and follows the selection.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 0) {
                tabViews
                Spacer(minLength: 0)
            }
            if rendersOffscreen {
                // A still image can't scroll: whole tabs around the selection, as the live strip
                // centres it, never a half-shown tab at an edge.
                LumenTabWindowLayout(selectedIndex: tabs.firstIndex { $0.id == selection } ?? 0) { tabViews }
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                    .clipped()
            } else {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    // Room past the last tab, so it can scroll clear of the fade: the selected tab is never faded.
                    HStack(spacing: 0) { tabViews }.padding(.trailing, metrics.spacing.s8)
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.scrollSpace)) } action: { contentFrame = $0 }
                }
                .coordinateSpace(.named(Self.scrollSpace))
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { viewportWidth = $0 }
                // Each edge fades only while tabs run past it, from the real scroll offset (the
                // leading edge used to end in a hard cut once the strip had scrolled).
                .mask { overflowFade(leading: contentFrame.minX < -0.5, trailing: contentFrame.maxX - metrics.spacing.s8 > viewportWidth + 0.5) }
                .onAppear { if let selection { proxy.scrollTo(selection, anchor: .center) } }
                // A window shrunk to its minimum after it appeared keeps the selected tab in view
                // (LIVE-06: only the pinned tab showed, the selected one scrolled out).
                .onChange(of: viewportWidth) { _, _ in if let selection { proxy.scrollTo(selection, anchor: .center) } }
                .onChange(of: selection) { _, id in
                    if let id { withAnimation(metrics.motion.animation(.snappy, reduceMotion: reduceMotion)) { proxy.scrollTo(id, anchor: .center) } }
                }
            }
            }
        }
        .lumenSelectionGroup(tabs.map { Optional($0.id) }, selection: $selection, focused: $focused)
        // Window › Select Previous/Next Tab (⇧⌘[ ⇧⌘]) through LumenViewCommands; these wrap, as Safari's do.
        .focusedSceneValue(\.lumenTabs, LumenTabNavigation(
            previous: { selection = LumenSelectionStep.next(tabs.map(\.id), from: selection, by: -1, wraps: true) },
            next: { selection = LumenSelectionStep.next(tabs.map(\.id), from: selection, by: 1, wraps: true) }))
        .frame(height: metrics.layout.tabHeight)
        .background(palette[.bgWindow])
        .overlay(alignment: .bottom) { Rectangle().fill(palette[.borderSubtle]).frame(height: metrics.stroke.hairline) }
        .modifier(TabDropTarget(enabled: actions.dropTab != nil && !rendersOffscreen) { drop($0, at: tabs.count) })
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Open documents")
    }
}

/// Lays out whole tabs only: the selected one and as many neighbours as fit, taken alternately after
/// and before it, so the selection sits near the middle, as the live strip scrolls it. Tabs outside
/// the window aren't shown (the still image's stand-in for scrolling).
struct LumenTabWindowLayout: Layout {
    let selectedIndex: Int

    static func window(_ widths: [CGFloat], selected: Int, available: CGFloat) -> ClosedRange<Int> {
        guard !widths.isEmpty else { return 0...0 }
        let selected = min(max(selected, 0), widths.count - 1)
        var low = selected, high = selected, total = widths[selected]
        var growRight = true, leftBlocked = false, rightBlocked = false
        while !(leftBlocked && rightBlocked) {
            if growRight, !rightBlocked {
                if high + 1 < widths.count, total + widths[high + 1] <= available { high += 1; total += widths[high] } else { rightBlocked = true }
            } else if !growRight, !leftBlocked {
                if low > 0, total + widths[low - 1] <= available { low -= 1; total += widths[low] } else { leftBlocked = true }
            }
            growRight.toggle()
        }
        return low...high
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let height = proposal.height ?? sizes.map(\.height).max() ?? 0
        return CGSize(width: proposal.width ?? sizes.reduce(0) { $0 + $1.width }, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let widths = subviews.map { $0.sizeThatFits(.unspecified).width }
        let shown = Self.window(widths, selected: selectedIndex, available: bounds.width)
        var x = bounds.minX
        for index in subviews.indices {
            let size = ProposedViewSize(width: widths[index], height: bounds.height)
            guard shown.contains(index) else {
                // Off the image: past the trailing edge, where the clip hides it.
                subviews[index].place(at: CGPoint(x: bounds.maxX + 10_000, y: bounds.minY), proposal: size)
                continue
            }
            subviews[index].place(at: CGPoint(x: x, y: bounds.minY), proposal: size)
            x += widths[index]
        }
    }
}

extension LumenDocumentTabBar {
    /// Tabs that run past the edge fade out rather than ending in a hard cut mid-word.
    private func overflowFade(leading: Bool, trailing: Bool) -> some View {
        HStack(spacing: 0) {
            if leading { LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing).frame(width: metrics.spacing.s8) }
            Rectangle()
            if trailing { LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: metrics.spacing.s8) }
        }
    }

    private var tabViews: some View {
        ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
            DocumentTabView(tab: tab, isSelected: tab.id == selection, isFocused: focused, onSelect: { selection = tab.id },
                            onClose: onClose.map { close in { close(tab) } }, actions: actions)
                .modifier(TabDropTarget(enabled: actions.dropTab != nil && !rendersOffscreen) { drop($0, at: index) })
        }
    }

    private func drop(_ items: [String], at index: Int) -> Bool {
        guard let item = items.first, let dragged = lumenTabDragContents(item) else { return false }
        if let moveTab = actions.moveTab {
            moveTab(dragged.tabID, dragged.pane, index)
        } else if let dropTab = actions.dropTab {
            dropTab(dragged.tabID, index)
        } else {
            return false
        }
        return true
    }
}

private struct DocumentTabView: View {
    let tab: LumenDocumentTab
    let isSelected: Bool
    let isFocused: Bool
    let onSelect: () -> Void
    let onClose: (() -> Void)?
    var actions = LumenTabActions()

    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenMetrics) private var metrics
    @Environment(\.lumenPaneIsFocused) private var paneIsFocused
    @Environment(\.lumenRendersOffscreen) private var rendersOffscreen
    @State private var isHovered = false
    @Environment(\.lumenForcedHover) private var forcedHover   // hover states in tests

    var body: some View {
        HStack(spacing: metrics.spacing.s2) {
            if tab.isPinned {
                LumenSymbol("pin.fill").font(.system(size: metrics.iconSize.micro)).foregroundStyle(palette[.fgTertiary]).accessibilityHidden(true)
            }
            LumenSymbol(tab.systemImage).foregroundStyle(palette[tab.hue])
            Text(tab.title)
                .italic(tab.isPreview)
                .foregroundStyle(palette[isSelected && paneIsFocused ? .fgPrimary : .fgSecondary])
                .lineLimit(1)
                .lumenNeverTruncates(tab.title)
            ZStack {
                if let onClose, isHovered || forcedHover {
                    Button("Close \(tab.title)", systemImage: "xmark", action: onClose)
                        .labelStyle(.iconOnly)
                        .lumenIconOnlyControl("Close Tab")
                        .buttonStyle(.plain)
                        .font(.system(size: metrics.iconSize.micro, weight: .bold))
                        .foregroundStyle(palette[.fgSecondary])
                        .frame(width: metrics.layout.minimumHitTarget, height: metrics.layout.minimumHitTarget)
                        .contentShape(.rect)
                        .focusable(false)
                        .help("Close Tab")
                } else if tab.isEdited {
                    Circle().fill(palette[.fgSecondary]).frame(width: metrics.layout.statusDot, height: metrics.layout.statusDot).accessibilityLabel("Edited")
                }
            }
            .frame(width: metrics.layout.minimumHitTarget, height: metrics.layout.minimumHitTarget)
        }
        .font(metrics.typography.callout)
        .padding(.leading, metrics.spacing.s5)
        .padding(.trailing, metrics.spacing.s1)
        .frame(minWidth: 130, maxHeight: .infinity, alignment: .leading)
        .background {
            if isSelected {
                Rectangle().fill(palette[.tabActiveFill]).opacity(paneIsFocused ? 1 : 0.5)
            } else if isHovered || forcedHover {
                Rectangle().fill(palette[.bgHover]).opacity(metrics.layout.hoverOpacity)
            }
        }
        .overlay(alignment: .top) {
            if isSelected {
                Rectangle().fill(paneIsFocused ? palette[tab.accent ?? .tabAccentBar] : palette[.borderDefault]).frame(height: 2)
            }
        }
        .lumenGroupFocusRing(isFocused && isSelected, cornerRadius: metrics.radius.xs)
        .overlay(alignment: .trailing) { Rectangle().fill(palette[.borderSubtle]).frame(width: metrics.stroke.hairline) }
        .contentShape(.rect)
        .onTapGesture(perform: onSelect)
        .onHover { isHovered = $0 }
        .modifier(TabInteractions(tab: tab, menu: menu, enabled: !rendersOffscreen))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(tab.title + (tab.isPinned ? ", pinned" : "") + (tab.isEdited ? ", edited" : ""))
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
        .accessibilityAction(.default, onSelect)
    }
    @ViewBuilder private var menu: some View {
        if let onClose { Button("Close Tab", action: onClose) }
        if let closeOthers = actions.closeOthers { Button("Close Other Tabs") { closeOthers(tab) } }
        if let closeAll = actions.closeAll { Button("Close All Tabs", action: closeAll) }
        if let togglePin = actions.togglePin {
            Divider()
            Button(tab.isPinned ? "Unpin Tab" : "Pin Tab") { togglePin(tab) }
        }
        if let path = tab.path {
            Divider()
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(path, forType: .string)
            }
        }
        if let duplicate = actions.duplicateInSplit {
            Divider()
            ForEach(LumenSplitEdge.allCases, id: \.self) { edge in Button(edge.title) { duplicate(tab, edge) } }
        }
    }

}

// MARK: Status bar

/// The editor's status bar: compact items grouped in a hairline capsule.
public struct LumenStatusBar<Content: View>: View {
    private let content: Content
    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenMetrics) private var metrics

    public init(@ViewBuilder content: () -> Content) { self.content = content() }

    public var body: some View {
        HStack(spacing: metrics.spacing.s4) { content }
            .font(metrics.typography.caption)
            .foregroundStyle(palette[.fgSecondary])
            .padding(.horizontal, metrics.spacing.s4)
            .frame(height: metrics.layout.minimumHitTarget)
            .overlay { Capsule(style: .circular).strokeBorder(palette[.borderSubtle], lineWidth: metrics.stroke.hairline) }
    }
}

/// A status bar item that picks one of several values: the value and a small chevron, opening a
/// native menu.
public struct LumenStatusMenu<Value: Hashable>: View {
    private let title: String
    @Binding private var selection: Value
    private let options: [Value]
    private let label: (Value) -> String

    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenMetrics) private var metrics
    @Environment(\.font) private var font

    /// - Parameters:
    ///   - title: the menu's spoken name ("Encoding").
    ///   - label: the text for a value, shown in the bar and in the menu.
    public init(_ title: String, selection: Binding<Value>, options: [Value], label: @escaping (Value) -> String) {
        self.title = title
        _selection = selection
        self.options = options
        self.label = label
    }

    public var body: some View {
        Menu {
            Picker(title, selection: $selection) {
                ForEach(options, id: \.self) { Text(label($0)).tag($0) }
            }
            .pickerStyle(.inline)
        } label: {
            // One Text, so the chevron stays after the value (a borderless menu puts images first). The
            // font goes on the label itself: a borderless menu ignores the one it inherits, so the
            // values were 13 pt beside the bar's caption text (LIVE-12).
            (Text("\(label(selection)) ") + Text(Image(systemName: "chevron.down")).font(.system(size: metrics.layout.disclosureGlyph, weight: .bold)))
                .font(font ?? metrics.typography.caption)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .tint(palette[.fgSecondary])
        .foregroundStyle(palette[.fgSecondary])
        // The borderless menu style draws no focus ring of its own.
        .lumenFocusRing(cornerRadius: metrics.radius.xs, inset: -3)
        .fixedSize()
        .help(title)
        .accessibilityLabel(title)
        .accessibilityValue(label(selection))
    }
}

public extension ButtonStyle where Self == LumenTintedButtonStyle {
    /// `LumenTintedButtonStyle`: a quiet accent-tinted button.
    static var lumenTinted: LumenTintedButtonStyle { LumenTintedButtonStyle() }
}

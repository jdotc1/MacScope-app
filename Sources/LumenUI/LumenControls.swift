import SwiftUI
import LumenTokens

// Settings controls: the tab strip on
// the box edge, round radios, and the card table with quiet headers.

// MARK: Tabbed box

/// Where a tabbed box's strip sits.
public enum LumenTabbedBoxStyle: Sendable {
    /// On the top edge of a bordered box, the content inside.
    case box
    /// Centered over a hairline at the top of a sheet, the content below.
    case header
}

/// Tabs that switch a box's content: a segmented strip sitting on the box's top edge, as settings
/// panes group Display / Editing / Indentation. The `.header` style puts the same strip at
/// the top of a sheet.
public struct LumenTabbedBox<Tab: Hashable, Content: View>: View {
    @Binding private var selection: Tab
    private let tabs: [Tab]
    private let title: (Tab) -> String
    private let style: LumenTabbedBoxStyle
    private let content: (Tab) -> Content

    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenMetrics) private var metrics

    public init(selection: Binding<Tab>, tabs: [Tab], style: LumenTabbedBoxStyle = .box, title: @escaping (Tab) -> String,
                @ViewBuilder content: @escaping (Tab) -> Content) {
        _selection = selection
        self.tabs = tabs
        self.title = title
        self.style = style
        self.content = content
    }

    /// The strip's rim around its segments: the pill switcher's.
    private var stripRim: CGFloat { metrics.layout.pillRim }

    /// The strip is one control height overall, rim included, as the pill switcher is (one height
    /// and one selection look for "pick one of N", §10); the box's top edge runs through its middle.
    private var stripHeight: CGFloat { metrics.layout.controlHeight }

    public var body: some View {
        switch style {
        case .box:
            ZStack(alignment: .top) {
                content(selection)
                    .padding(.horizontal, metrics.spacing.s6)
                    .padding(.top, metrics.spacing.s6 + stripHeight / 2)
                    .padding(.bottom, metrics.spacing.s6)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .lumenChrome(.card)
                    .padding(.top, stripHeight / 2)
                foldingStrip
            }
        case .header:
            VStack(spacing: 0) {
                foldingStrip.padding(.vertical, metrics.spacing.s5)
                Rectangle().fill(palette[.borderSubtle]).frame(height: metrics.stroke.hairline)
                content(selection).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }

    /// The strip, or a pop-up of the tabs when the box is too narrow for every tab (§6: rows of
    /// controls fold rather than overflow).
    private var foldingStrip: some View {
        ViewThatFits(in: .horizontal) {
            strip
            LumenPopUp(selection: $selection, options: tabs, title: title)
                .frame(height: stripHeight)
        }
    }

    private var strip: some View {
        HStack(spacing: metrics.spacing.s1) {
            ForEach(tabs, id: \.self) { tab in
                let selected = tab == selection
                Button { selection = tab } label: {
                    Text(title(tab))
                        .font(selected ? metrics.typography.bodyEmphasized : metrics.typography.body)
                        .foregroundStyle(palette[selected ? .accentFilledForeground : .fgSecondary])
                        .lineLimit(1)
                        .lumenNeverTruncates(title(tab))
                        .padding(.horizontal, metrics.spacing.s5 - 2)
                        .frame(height: stripHeight - 2 * stripRim)
                        // The one segmented selection: a filled accent capsule under white.
                        .background(selected ? palette[.accentFilled] : .clear, in: .capsule)
                        .contentShape(.capsule)
                }
                .buttonStyle(.lumenBare)
                .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
            }
        }
        .padding(stripRim)
        // The pill switcher's track: a field's well with a control's edge.
        .background(palette[.bgInset], in: .capsule)
        .overlay { Capsule(style: .circular).strokeBorder(palette[.borderDefault], lineWidth: metrics.stroke.hairline) }
        .fixedSize()
        .accessibilityElement(children: .contain)
    }
}

// MARK: Radio group

/// One round radio and its label, drawn like `.lumenCheckbox`: the filled accent (`accent.filled`)
/// and a white dot when chosen, a `border.control` ring when not. `LumenRadioGroup` lays several
/// out; use this alone for custom layouts.
public struct LumenRadioButton: View {
    private let title: String
    private let isSelected: Bool
    private let action: () -> Void

    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenMetrics) private var metrics
    @Environment(\.isEnabled) private var isEnabled

    public init(_ title: String, isSelected: Bool, action: @escaping () -> Void) {
        self.title = title
        self.isSelected = isSelected
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: metrics.spacing.s3) {
                let size = metrics.layout.toggleIndicator
                Circle()
                    .fill(isSelected ? palette[.accentFilled] : palette[.bgInset])
                    .overlay { Circle().strokeBorder(palette[isSelected ? .accentFilled : .borderControl], lineWidth: metrics.stroke.hairline) }
                    .overlay { if isSelected { Circle().fill(palette[.accentFilledForeground]).frame(width: (size * 0.4).rounded(), height: (size * 0.4).rounded()) } }
                    .frame(width: size, height: size)
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 3 }
                Text(title).foregroundStyle(palette[.fgPrimary]).lumenWrapsWithoutTruncating()
            }
            .contentShape(.rect)
        }
        .buttonStyle(.lumenBare)
        .lumenDisabledFade(isEnabled)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }
}

/// A choice of one among a few, as round radios in a column. An option can own detail (a list, a
/// field) indented under it, enabled only while that option is chosen ("Only if there are
/// processes other than: [rlogin, ssh…]").
public struct LumenRadioGroup<Value: Hashable, Detail: View>: View {
    @Binding private var selection: Value
    private let options: [Value]
    private let title: (Value) -> String
    private let detail: (Value) -> Detail

    @Environment(\.lumenMetrics) private var metrics

    /// - Parameter detail: what sits under an option; return `EmptyView()` for options without any.
    public init(selection: Binding<Value>, options: [Value], title: @escaping (Value) -> String,
                @ViewBuilder detail: @escaping (Value) -> Detail) {
        _selection = selection
        self.options = options
        self.title = title
        self.detail = detail
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: metrics.spacing.s4) {
            ForEach(options, id: \.self) { option in
                VStack(alignment: .leading, spacing: metrics.spacing.s3) {
                    LumenRadioButton(title(option), isSelected: option == selection) { selection = option }
                    detail(option)
                        .padding(.leading, metrics.layout.toggleIndicator + metrics.spacing.s3)
                        .disabled(option != selection)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }
}

public extension LumenRadioGroup where Detail == EmptyView {
    init(selection: Binding<Value>, options: [Value], title: @escaping (Value) -> String) {
        self.init(selection: selection, options: options, title: title) { _ in EmptyView() }
    }
}

// MARK: Table

/// A column of a `LumenTable`: a header and how each row draws in it.
public struct LumenTableColumn<Row>: Identifiable {
    public let id: String
    let title: String
    let width: CGFloat?
    let alignment: Alignment
    let cell: (Row) -> AnyView
    var minWidth: CGFloat?
    var headerView: AnyView?
    var priority: Double = 0

    /// - Parameter width: a fixed width; `nil` shares the remaining space.
    public init<Cell: View>(_ title: String, width: CGFloat? = nil, alignment: Alignment = .leading,
                            @ViewBuilder cell: @escaping (Row) -> Cell) {
        id = title
        self.title = title
        self.width = width
        self.alignment = alignment
        self.cell = { AnyView(cell($0)) }
    }

    /// The least width of a shared column, so it keeps a readable share when the table is narrow
    /// (about 9 characters for names and types in an inspector).
    public func minWidth(_ width: CGFloat) -> LumenTableColumn {
        var column = self
        column.minWidth = width
        return column
    }

    /// Draws the header as a view (a glyph for an evidence column). The title stays the column's
    /// accessibility label and help tag.
    public func header<Header: View>(@ViewBuilder _ header: () -> Header) -> LumenTableColumn {
        var column = self
        column.headerView = AnyView(header())
        return column
    }

    /// The order shared columns give up width when the table is narrow: higher keeps its width
    /// longer (default 0). Each column shrinks to its `minWidth` before the next priority shrinks.
    public func priority(_ priority: Double) -> LumenTableColumn {
        var column = self
        column.priority = priority
        return column
    }
}

/// How a table's shared columns split its width. No column cuts its text while another has slack:
/// each wants its natural one-line width (at least its minimum) and gets an equal share of what's
/// left. Short of room, columns shrink from the lowest priority up, each to its minimum (ties shrink
/// in proportion), and only then below their minimums, all in proportion.
enum LumenTableLayout {
    static func widths(natural: [CGFloat], minimums: [CGFloat], priorities: [Double], available: CGFloat) -> [CGFloat] {
        let available = max(available, 0)
        var widths = zip(natural, minimums).map { max($0, $1) }
        guard !widths.isEmpty else { return [] }
        let wanted = widths.reduce(0, +)
        if wanted <= available {
            let share = (available - wanted) / CGFloat(widths.count)
            return widths.map { $0 + share }
        }
        var deficit = wanted - available
        for priority in Set(priorities).sorted() {
            let group = widths.indices.filter { priorities[$0] == priority }
            let room = group.reduce(CGFloat(0)) { $0 + max(widths[$1] - minimums[$1], 0) }
            guard room > 0 else { continue }
            let take = min(deficit, room)
            for index in group { widths[index] -= max(widths[index] - minimums[index], 0) * take / room }
            deficit -= take
            if deficit <= 0.001 { return widths }
        }
        let total = widths.reduce(0, +)
        return total > 0 ? widths.map { $0 * available / total } : widths
    }
}

/// Natural one-line widths of shared columns, by column id.
private struct LumenTableNaturalWidthKey: PreferenceKey {
    static let defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: max)
    }
}

private struct LumenTableWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

extension EnvironmentValues {
    /// True inside the hidden copy a table lays out to measure a cell's natural width.
    @Entry var lumenTableMeasuring = false
}

/// Reports the natural one-line width of a cell or header, from a hidden copy laid out unconstrained.
private struct LumenTableMeasure: ViewModifier {
    let id: String

    func body(content: Content) -> some View {
        content.background {
            content
                .fixedSize()
                .hidden()
                .environment(\.lumenTableMeasuring, true)
                .environment(\.lumenVisibleTextColumn, nil)   // the full-width copy shows nothing
                .background {
                    GeometryReader { natural in
                        Color.clear.preference(key: LumenTableNaturalWidthKey.self, value: [id: natural.size.width])
                    }
                }
                .accessibilityHidden(true)
        }
    }
}

public extension LumenTableColumn {
    /// A column of text, monospaced for keys, paths and escape sequences.
    @MainActor static func text(_ title: String, width: CGFloat? = nil, alignment: Alignment = .leading, monospaced: Bool = false,
                     value: @escaping (Row) -> String) -> LumenTableColumn {
        LumenTableColumn(title, width: width, alignment: alignment) { row in
            LumenTableText(value(row), monospaced: monospaced)
        }
    }

    /// A column of text that ends where `truncationMode` says: `.middle` for values that differ at
    /// the end (members sharing a stem, types sharing a module prefix).
    @MainActor static func text(_ title: String, width: CGFloat? = nil, alignment: Alignment = .leading, monospaced: Bool = false,
                                truncationMode: Text.TruncationMode, value: @escaping (Row) -> String) -> LumenTableColumn {
        LumenTableColumn(title, width: width, alignment: alignment) { row in
            LumenTableText(value(row), monospaced: monospaced, truncationMode: truncationMode)
        }
    }
}

/// A cell's text in the table's type. Text too long for its cell ends in an ellipsis, never cut
/// mid-word, and shows in full as a help tag.
public struct LumenTableText: View {
    private let text: String
    private let monospaced: Bool
    private var truncationMode: Text.TruncationMode = .tail

    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenMetrics) private var metrics
    @Environment(\.lumenCodeFont) private var codeFont
    @Environment(\.lumenTableMeasuring) private var measuring
    @Environment(\.lumenReportsLayoutChecks) private var reportsChecks

    /// A cell may end in an ellipsis, but it always shows at least this many characters first: a
    /// name cut to two letters tells the reader nothing.
    public static let minimumVisibleCharacters = 8

    public init(_ text: String, monospaced: Bool = false) {
        self.text = text
        self.monospaced = monospaced
    }

    /// Text that ends where `truncationMode` says. With `.middle` the floor is 4 characters each
    /// side of the ellipsis ("Calc…Mode"); with `.head`, the last 8.
    public init(_ text: String, monospaced: Bool = false, truncationMode: Text.TruncationMode) {
        self.init(text, monospaced: monospaced)
        self.truncationMode = truncationMode
    }

    public var body: some View {
        let font = monospaced ? (codeFont ?? .standard).font(sizeDelta: -1) : metrics.typography.callout
        Text(text)
            .font(font)
            .foregroundStyle(palette[.fgPrimary])
            .lineLimit(1)
            .truncationMode(truncationMode)
            .help(text)
            .background {
                // Reports the cell to the truncation checks when it shows fewer than the minimum
                // characters before its ellipsis. The table's own hidden measuring copy skips this.
                if !measuring && reportsChecks { minimumWidthWatch(font) }
            }
            // What the cell shows at its width, for the check that two values in one column never
            // shorten to the same text. The column comes from `LumenTable` (unset in the measuring copy).
            .lumenReportsVisibleText(text, font: nsFont, truncation: truncationMode)
    }

    /// The AppKit face the cell draws in, for measuring what it shows.
    private var nsFont: NSFont {
        monospaced ? (codeFont ?? .standard).nsFont(sizeDelta: -1) : NSFont.preferredFont(forTextStyle: .callout)
    }

    private func minimumWidthWatch(_ font: Font) -> some View {
        let n = Self.minimumVisibleCharacters
        // Text barely over the floor must show in full: "Find Nex…" is wider than "Find Next", so the
        // eight-character form would report a cell that shows every character.
        let shortest: String = if text.count <= n + 2 {
            text
        } else {
            switch truncationMode {
            case .middle: String(text.prefix(n / 2)) + "…" + String(text.suffix(n - n / 2))
            case .head: "…" + String(text.suffix(n))
            default: String(text.prefix(n)) + "…"
            }
        }
        return GeometryReader { actual in
            Text(shortest).font(font).fixedSize().hidden()
                .background {
                    GeometryReader { needed in
                        Color.clear.preference(key: LumenTruncationKey.self,
                                               value: actual.size.width + 0.5 < needed.size.width   // a column squeezed to nothing counts too
                                                   ? ["\(text) (fewer than \(n) characters show)"] : [])
                    }
                }
        }
        .accessibilityHidden(true)
    }
}

/// A lazy stack doesn't pass preferences up, so each row hands its cells' truncation and
/// visible-text reports to the table, which reports them for the conformance checks. Only where
/// checks run (`lumenReportsLayoutChecks`): each report writes the table's state, and in a shipping
/// app that re-evaluated the whole table for every row scrolled in or out (PERF-09).
private struct LumenTableRowReports<ID: Hashable>: ViewModifier {
    let isActive: Bool
    @Binding var truncations: [ID: Set<String>]
    @Binding var visibleTexts: [ID: Set<LumenVisibleTextEntry>]
    let id: ID

    func body(content: Content) -> some View {
        if isActive {
            content
                .onPreferenceChange(LumenTruncationKey.self) { labels in
                    MainActor.assumeIsolated {
                        if truncations[id, default: []] != labels { truncations[id] = labels.isEmpty ? nil : labels }
                    }
                }
                .onPreferenceChange(LumenVisibleTextKey.self) { entries in
                    MainActor.assumeIsolated {
                        if visibleTexts[id, default: []] != entries { visibleTexts[id] = entries.isEmpty ? nil : entries }
                    }
                }
                // A row scrolled out of a lazy stack stops reporting.
                .onDisappear { truncations[id] = nil; visibleTexts[id] = nil }
        } else {
            content
        }
    }
}

/// A table's bottom bar: + and − (and ✎ when rows can be edited), then a trailing text action
/// ("Restore Defaults"). Pass `nil` for a button the table doesn't offer; − and ✎ need a selection.
public struct LumenTableFooter {
    let onAdd: (() -> Void)?
    let onRemove: (() -> Void)?
    let onEdit: (() -> Void)?
    let trailing: (title: String, action: () -> Void)?

    public init(onAdd: (() -> Void)? = nil, onRemove: (() -> Void)? = nil, onEdit: (() -> Void)? = nil,
                trailing: (title: String, action: () -> Void)? = nil) {
        self.onAdd = onAdd
        self.onRemove = onRemove
        self.onEdit = onEdit
        self.trailing = trailing
    }
}

/// How tall a `LumenTable`'s rows area is.
public enum LumenTableHeight: Sendable, Equatable {
    /// At least this tall, so an empty table still reads as a table; rows past it scroll.
    case minimum(CGFloat)
    /// Hugs its rows, up to `maxVisible` of them, then scrolls (MacScope's member lists): no hand
    /// estimate of row heights, and no dead band under the last row.
    case fitRows(maxVisible: Int)
}

/// Rows in columns on a card like `LumenSettingsCard`: quiet small-caps headers, hairlines between rows, the
/// selection in `bg.selected`, a message when empty, and the +/− footer inside the card. Cells are any
/// view, so a column can hold a field, a pop-up or a checkbox for editing in place.
public struct LumenTable<Row: Identifiable>: View {
    private let rows: [Row]
    private let columns: [LumenTableColumn<Row>]
    @Binding private var selection: Row.ID?
    private let emptyMessage: String
    private let footer: LumenTableFooter?
    private let height: LumenTableHeight
    private let footnote: String?

    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenMetrics) private var metrics
    @Environment(\.lumenRendersOffscreen) private var rendersOffscreen
    @Environment(\.lumenDensity) private var density
    @Environment(\.controlActiveState) private var activeState
    @Environment(\.lumenReportsLayoutChecks) private var reportsChecks
    /// Cells' truncation reports, carried out of the scrolling rows (a lazy stack in a scroll view
    /// doesn't pass preferences up) so the conformance checks see them.
    @State private var cellTruncations: [Row.ID: Set<String>] = [:]
    /// Cells' visible-text reports (`.lumenReportsVisibleText`), carried out the same way.
    @State private var cellVisibleTexts: [Row.ID: Set<LumenVisibleTextEntry>] = [:]
    @State private var naturalWidths: [String: CGFloat] = [:]
    @State private var tableWidth: CGFloat = 0
    /// Measured row heights, for `.fitRows`.
    @State private var rowHeights: [Row.ID: CGFloat] = [:]

    /// - Parameters:
    ///   - selection: the selected row; click a row to select it.
    ///   - emptyMessage: shown in place of rows when there are none.
    ///   - footer: the +/− bar under the rows; `nil` for none.
    ///   - minHeight: the least height of the rows area, so an empty table still reads as a table.
    ///   - columns: the columns, left to right; a column without a width shares the rest.
    public init(_ rows: [Row], selection: Binding<Row.ID?>, emptyMessage: String = "No items",
                footer: LumenTableFooter? = nil, minHeight: CGFloat = 120, columns: [LumenTableColumn<Row>]) {
        self.init(rows, selection: selection, emptyMessage: emptyMessage, footer: footer, height: .minimum(minHeight),
                  footnote: nil, columns: columns)
    }

    /// - Parameters:
    ///   - height: `.fitRows(maxVisible:)` hugs the rows; `.minimum(_:)` keeps a least height.
    ///   - footnote: a note under the rows, in caption type on the cells' text column ("Unknown
    ///     layout: offsets aren't recorded").
    public init(_ rows: [Row], selection: Binding<Row.ID?>, emptyMessage: String = "No items",
                footer: LumenTableFooter? = nil, height: LumenTableHeight, footnote: String? = nil,
                columns: [LumenTableColumn<Row>]) {
        self.rows = rows
        self.columns = columns
        _selection = selection
        self.emptyMessage = emptyMessage
        self.footer = footer
        self.height = height
        self.footnote = footnote
    }

    /// One row's height before it has been measured: a row and its hairline.
    private var estimatedRowHeight: CGFloat { density.rowHeight(in: metrics.layout) + metrics.stroke.hairline }

    public var body: some View {
        VStack(spacing: 0) {
            header
            rowsArea
                .transformPreference(LumenTruncationKey.self) { labels in
                    for row in cellTruncations.values { labels.formUnion(row) }
                }
                .transformPreference(LumenVisibleTextKey.self) { entries in
                    for row in cellVisibleTexts.values { entries.formUnion(row) }
                }
            if let footnote {
                Rectangle().fill(palette[.borderSubtle]).frame(height: metrics.stroke.hairline)
                    .padding(.horizontal, metrics.spacing.s2)
                Text(footnote)
                    .font(metrics.typography.caption)
                    .foregroundStyle(palette[.fgTertiary])
                    .lumenWrapsWithoutTruncating()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, metrics.spacing.s5 + metrics.spacing.s2)   // the cells' text column
                    .padding(.vertical, metrics.spacing.s3)
            }
            if let footer {
                // Inset like the header's and the rows' hairlines: one rule for every line in the table.
                Rectangle().fill(palette[.borderSubtle]).frame(height: metrics.stroke.hairline)
                    .padding(.horizontal, metrics.spacing.s2)
                footerBar(footer)
            }
        }
        .background {
            if !rendersOffscreen {
                GeometryReader { proxy in Color.clear.preference(key: LumenTableWidthKey.self, value: proxy.size.width) }
            }
        }
        .onPreferenceChange(LumenTableNaturalWidthKey.self) { widths in
            MainActor.assumeIsolated { if naturalWidths != widths { naturalWidths = widths } }
        }
        .onPreferenceChange(LumenTableWidthKey.self) { width in
            MainActor.assumeIsolated { if tableWidth != width { tableWidth = width } }
        }
        // A table inside a table measures its own columns only.
        .transformPreference(LumenTableNaturalWidthKey.self) { $0 = [:] }
        .transformPreference(LumenTableWidthKey.self) { $0 = 0 }
        .lumenChrome(.card)
        // Rows that are gone no longer report truncations. Only tracked where there are reports or
        // measured heights to prune (PERF-09: mapping every id on each body cost every scroll step).
        .onChange(of: reportsChecks || measuresRows ? rows.map(\.id) : []) { _, ids in
            let current = Set(ids)
            cellTruncations = cellTruncations.filter { current.contains($0.key) }
            cellVisibleTexts = cellVisibleTexts.filter { current.contains($0.key) }
            rowHeights = rowHeights.filter { current.contains($0.key) }
        }
        .accessibilityElement(children: .contain)
    }

    /// The rows, or the empty message under the header's hairline. One view per case, so the
    /// height applies to the whole area (a frame on a `Group` of two views framed each one: the
    /// empty table's hairline floated in a band of its own).
    @ViewBuilder private var rowsArea: some View {
        if rows.isEmpty {
            VStack(spacing: 0) {
                // The header keeps its hairline with no rows under it, as with rows.
                Rectangle().fill(palette[.borderSubtle]).frame(height: metrics.stroke.hairline)
                    .padding(.horizontal, metrics.spacing.s2)
                // The inline empty state, centered in the rows' area.
                LumenEmptyState(emptyMessage, prominence: .inline)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(minHeight: emptyHeight)
        } else {
            switch height {
            case .minimum(let minHeight):
                Group {
                    if rendersOffscreen {
                        rowStack.frame(maxHeight: .infinity, alignment: .top)
                    } else {
                        ScrollView { rowStack }
                    }
                }
                .frame(minHeight: minHeight)
            case .fitRows(let maxVisible):
                if rendersOffscreen || rows.count <= maxVisible {
                    rowStack.lumenWrapsWithoutTruncating()
                } else {
                    let visible = rows.prefix(max(maxVisible, 1)).reduce(CGFloat(0)) { $0 + (rowHeights[$1.id] ?? estimatedRowHeight) }
                    ScrollView { rowStack }.frame(height: visible)
                }
            }
        }
    }

    private var emptyHeight: CGFloat {
        switch height {
        case .minimum(let minHeight): minHeight
        case .fitRows: 2 * density.rowHeight(in: metrics.layout)
        }
    }

    private var measuresRows: Bool {
        if case .fitRows = height { return !rendersOffscreen }
        return false
    }

    /// One width per column, shared by the header and every row so columns line up; `nil` until the
    /// table has measured itself (and always offscreen, where shared columns split the rest equally).
    private var columnWidths: [CGFloat]? {
        guard !rendersOffscreen, tableWidth > 0 else { return nil }
        let flexible = columns.indices.filter { columns[$0].width == nil }
        guard !flexible.isEmpty, flexible.allSatisfy({ naturalWidths[columns[$0].id] != nil }) else { return nil }
        let fixed = columns.compactMap(\.width).reduce(0, +)
        let spacing = metrics.spacing.s5 * CGFloat(max(columns.count - 1, 0))
        let padding = 2 * (metrics.spacing.s5 + metrics.spacing.s2)
        let shared = LumenTableLayout.widths(natural: flexible.map { naturalWidths[columns[$0].id] ?? 0 },
                                             minimums: flexible.map { columns[$0].minWidth ?? 0 },
                                             priorities: flexible.map { columns[$0].priority },
                                             available: tableWidth - fixed - spacing - padding)
        var widths = columns.map { $0.width ?? 0 }
        for (index, width) in zip(flexible, shared) { widths[index] = width }
        return widths
    }

    @ViewBuilder private func sized<Content: View>(_ content: Content, _ column: LumenTableColumn<Row>, width: CGFloat?) -> some View {
        if rendersOffscreen {
            content
                .frame(width: column.width, alignment: column.alignment)
                .frame(minWidth: column.minWidth, maxWidth: column.width == nil ? .infinity : nil, alignment: column.alignment)
        } else if column.width != nil {
            content.frame(width: column.width, alignment: column.alignment)
        } else {
            let measured = content.modifier(LumenTableMeasure(id: column.id))
            if let width {
                measured.frame(width: width, alignment: column.alignment)
            } else {
                // Before the table has measured itself: no minimums here, or they'd push the table past
                // its container, and it would then measure that inflated width (MacScope's Types
                // inspector clipped on both edges). The measured widths apply the minimums, and they
                // yield when the table has no room.
                measured.frame(maxWidth: .infinity, alignment: column.alignment)
            }
        }
    }

    private var header: some View {
        let widths = columnWidths
        return HStack(spacing: metrics.spacing.s5) {
            ForEach(Array(columns.enumerated()), id: \.element.id) { index, column in
                sized(headerCell(column), column, width: widths?[index])
                    .accessibilityAddTraits(.isHeader)
            }
        }
        .padding(.horizontal, metrics.spacing.s5 + metrics.spacing.s2)
        .frame(height: density.rowHeight(in: metrics.layout))
    }

    @ViewBuilder private func headerCell(_ column: LumenTableColumn<Row>) -> some View {
        if let headerView = column.headerView {
            headerView
                .foregroundStyle(palette[.fgTertiary])
                .help(column.title)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(column.title)
        } else {
            // The one section-label style, shared with group labels.
            Text(column.title)
                .lumenSectionLabel()
                .lumenNeverTruncates(column.title.uppercased())
        }
    }

    private var rowStack: some View {
        // The hairlines between rows give way next to the selection plate, which already separates
        // its row; the header's hairline (above the first row) stays.
        let afterSelection = selection.flatMap { id in rows.firstIndex { $0.id == id } }
            .flatMap { rows.indices.contains($0 + 1) ? rows[$0 + 1].id : nil }
        let firstID = rows.first?.id
        return LazyVStack(spacing: 0) {
            ForEach(rows) { row in
                VStack(spacing: 0) {
                    // The row hairlines share the selection band's inset (§8), so the band and the
                    // lines above and below it start and end at the same x.
                    Rectangle().fill(palette[.borderSubtle]).frame(height: metrics.stroke.hairline)
                        .padding(.horizontal, metrics.spacing.s2)
                        .opacity(row.id != firstID && (row.id == selection || row.id == afterSelection) ? 0 : 1)
                    cells(row)
                }
                .modifier(LumenTableRowHeight(isActive: measuresRows) { height in
                    if rowHeights[row.id] != height { rowHeights[row.id] = height }
                })
                .modifier(LumenTableRowReports(isActive: reportsChecks, truncations: $cellTruncations, visibleTexts: $cellVisibleTexts, id: row.id))
            }
        }
    }

    private func cells(_ row: Row) -> some View {
        let selected = selection == row.id
        let widths = columnWidths
        return HStack(spacing: metrics.spacing.s5) {
            ForEach(Array(columns.enumerated()), id: \.element.id) { index, column in
                sized(column.cell(row).environment(\.lumenVisibleTextColumn, reportsChecks ? column.title : nil), column, width: widths?[index])
            }
        }
        .padding(.horizontal, metrics.spacing.s5)
        .frame(minHeight: density.rowHeight(in: metrics.layout))
        // The navigation family's quiet selection, from the one row rule: it goes quieter when the
        // window loses key, as every content list does (§10).
        .lumenRowBackground(LumenRowState.resolve(isSelected: selected, isActiveWindow: activeState != .inactive))
        .contentShape(.rect)
        .onTapGesture { selection = row.id }
        .padding(.horizontal, metrics.spacing.s2)
        // Each row is its own element and keeps its cells addressable, so fields in a cell stay editable.
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private func footerBar(_ footer: LumenTableFooter) -> some View {
        HStack(spacing: 0) {
            if let onAdd = footer.onAdd { footerButton("plus", "Add", action: onAdd, enabled: true) }
            if let onRemove = footer.onRemove {
                if footer.onAdd != nil { divider }
                footerButton("minus", "Remove", action: onRemove, enabled: selection != nil)
            }
            if let onEdit = footer.onEdit {
                if footer.onAdd != nil || footer.onRemove != nil { divider }
                footerButton("pencil", "Edit", action: onEdit, enabled: selection != nil)
            }
            Spacer(minLength: metrics.spacing.s4)
            if let trailing = footer.trailing {
                Button(trailing.title, action: trailing.action)
                    .buttonStyle(.plain)
                    .font(metrics.typography.caption.weight(.medium))
                    .foregroundStyle(palette[.fgSecondary])
                    .padding(.trailing, metrics.spacing.s4)
            }
        }
        .padding(.horizontal, metrics.spacing.s2)
        .frame(height: metrics.layout.subheaderHeight)
    }

    private var divider: some View {
        LumenInlineDivider()
    }

    private func footerButton(_ symbol: String, _ title: String, action: @escaping () -> Void, enabled: Bool) -> some View {
        LumenGlyphButton(systemImage: symbol, title: title, enabled: enabled, action: action)
    }
}

/// Reports a row's height while active (a `.fitRows` table sizes itself from its first rows).
private struct LumenTableRowHeight: ViewModifier {
    let isActive: Bool
    let report: (CGFloat) -> Void

    func body(content: Content) -> some View {
        if isActive {
            content.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { report($0) }
        } else {
            content
        }
    }
}

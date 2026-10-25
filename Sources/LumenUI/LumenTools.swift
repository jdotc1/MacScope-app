import AppKit
import SwiftUI
import LumenTokens

// The All Sidebars grid, a shortcut recorder, a completion list and a
// collection that switches between a zoomable grid and a sortable list.

// MARK: Sidebar pane grid

/// Every sidebar pane as a grid of tiles, the docked ones checked. Click a tile to dock or undock it; drag one onto the switcher to dock it there. The
/// last docked pane stays. Shares `arrangement` with `LumenSidebarSwitcher`.
public struct LumenSidebarPaneGrid: View {
    private let items: [LumenSidebarItem]
    @Binding private var arrangement: String

    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenMetrics) private var metrics
    @Environment(\.lumenRendersOffscreen) private var rendersOffscreen

    public init(_ items: [LumenSidebarItem], arrangement: Binding<String>) {
        self.items = items
        _arrangement = arrangement
    }

    private var layout: LumenToolLayout { LumenToolLayout(encoded: arrangement, all: items.map(\.id)) }

    public var body: some View {
        let layout = layout
        VStack(alignment: .leading, spacing: metrics.spacing.s3) {
            Text("Click a pane to add it to the dock or take it out, or drag it onto the dock.")
                .font(metrics.typography.caption).foregroundStyle(palette[.sidebarSecondaryForeground])
                .lumenWrapsWithoutTruncating()
            LazyVGrid(columns: [GridItem(.adaptive(minimum: metrics.layout.sidebarTileMinWidth), spacing: metrics.spacing.s2)], spacing: metrics.spacing.s4) {
                ForEach(items) { item in tile(item, docked: layout.visible.contains(item.id), isLast: layout.visible == [item.id]) }
            }
        }
        .padding(metrics.spacing.s3)
    }

    private func tile(_ item: LumenSidebarItem, docked: Bool, isLast: Bool) -> some View {
        Button {
            var next = layout
            if docked { _ = next.hide(item.id) } else { next.show(item.id) }
            arrangement = next.encoded
        } label: {
            VStack(spacing: metrics.spacing.s2) {
                // Full color whether docked or not (PRINCIPLES §7): the check badge marks the dock.
                LumenIconTile(item.systemImage, hue: item.hue ?? .accent, size: metrics.layout.tileTool)
                    .lumenIconRole(.control)
                    .overlay(alignment: .bottomTrailing) {
                        if docked {
                            // A filled accent shape: the deep accent under white (§10), with a check big enough to read.
                            Circle().fill(palette[.accentFilled]).frame(width: 12, height: 12)
                                .overlay { LumenSymbol("checkmark").font(.system(size: metrics.iconSize.micro, weight: .bold)).foregroundStyle(palette[.accentFilledForeground]) }
                                .overlay { Circle().strokeBorder(palette[.sidebarBackground], lineWidth: metrics.stroke.regular) }
                                .offset(x: 4, y: 4)
                        }
                    }
                // Regular weight: docking is marked by the badge, not by louder type (calm type).
                Text(item.title).font(.caption2).foregroundStyle(palette[.sidebarForeground])
                    .multilineTextAlignment(.center).lineLimit(2)
                    .help(item.title)
            }
            .frame(maxWidth: .infinity)
            .contentShape(.rect)
        }
        .buttonStyle(.lumenBare)
        .disabled(docked && isLast)
        .lumenDisabledFade(!(docked && isLast))
        .modifier(PaneDragSource(id: item.id, title: item.title, enabled: !rendersOffscreen))
        .help(docked ? (isLast ? "The last pane in the dock stays" : "Take \(item.title) out of the dock") : "Add \(item.title) to the dock")
        .accessibilityLabel(item.title)
        .accessibilityValue(docked ? "In the dock" : "Not in the dock")
    }
}

/// A sidebar pane's drag source, left off offscreen.
private struct PaneDragSource: ViewModifier {
    let id: String
    let title: String
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled { content.draggable(lumenPaneDragPrefix + id) { Text(title).padding(6) } } else { content }
    }
}

// MARK: Shortcut recorder

/// Records a keyboard shortcut: the shortcut as keycaps in a field; click to
/// record (an accent outline and "Type shortcut"), then press the keys. Escape cancels, Delete
/// clears, ⊖ clears. Shortcuts need ⌘, ⌃ or ⌥, except function keys. `conflict` shows a warning.
public struct LumenShortcutRecorder: View {
    @Binding private var shortcut: KeyboardShortcut?
    private let conflict: String?
    private let width: CGFloat

    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenMetrics) private var metrics
    @State private var recording = false
    @State private var monitor = RecorderMonitor()
    @FocusState private var focused: Bool

    /// - Parameter conflict: what else uses this shortcut, shown as a warning's help.
    public init(shortcut: Binding<KeyboardShortcut?>, conflict: String? = nil, width: CGFloat = 130) {
        _shortcut = shortcut
        self.conflict = conflict
        self.width = width
    }

    init(shortcut: Binding<KeyboardShortcut?>, conflict: String?, width: CGFloat, recording: Bool) {
        self.init(shortcut: shortcut, conflict: conflict, width: width)
        _recording = State(initialValue: recording)
    }

    static let functionKeys: Set<Character> = Set((0xF704...0xF70F).compactMap { UnicodeScalar($0).map(Character.init) })

    /// The shortcut a key press records, or `nil` when it can't be one: plain letters without ⌘, ⌃ or
    /// ⌥ (they'd fire while typing), except function keys.
    static func shortcut(for key: KeyEquivalent, modifiers: EventModifiers) -> KeyboardShortcut? {
        let relevant = modifiers.intersection([.command, .control, .option, .shift])
        let hasPrimary = !relevant.intersection([.command, .control, .option]).isEmpty
        guard hasPrimary || functionKeys.contains(key.character) else { return nil }
        return KeyboardShortcut(key, modifiers: relevant)
    }

    public var body: some View {
        HStack(spacing: metrics.spacing.s2) {
            if let conflict {
                LumenSymbol("exclamationmark.triangle.fill").font(.caption).foregroundStyle(palette[.statusWarning])
                    .help(conflict).accessibilityLabel("Conflict: \(conflict)")
            }
            Button { recording = true; focused = true } label: {
                HStack(spacing: metrics.spacing.s1) {
                    if recording {
                        Text("Type shortcut").font(metrics.typography.caption).foregroundStyle(palette[.accent])
                    } else if let shortcut {
                        LumenKeycap(shortcut)
                    } else {
                        Text("⌘").font(metrics.typography.caption).foregroundStyle(palette[.fgTertiary])
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, metrics.spacing.s2)
                // Room at the trailing end for Clear, which sits over the field, not inside the
                // button's label (nested buttons are unreliable on macOS).
                .padding(.trailing, recording || shortcut != nil ? metrics.layout.minimumHitTarget - metrics.spacing.s2 : 0)
                .frame(width: width, height: metrics.layout.controlHeight)
                .lumenChrome(.field, focused: recording)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .focusable()
            .focused($focused)
            .focusEffectDisabled()
            .overlay(alignment: .trailing) {
                if recording || shortcut != nil {
                    Button("Clear", systemImage: "xmark.circle.fill") { shortcut = nil; recording = false }
                        .labelStyle(.iconOnly).buttonStyle(.plain).font(.caption).foregroundStyle(palette[.fgTertiary])
                        .frame(width: metrics.layout.minimumHitTarget, height: metrics.layout.controlHeight)
                        .contentShape(.rect)
                        .lumenIconOnlyControl("Clear shortcut")
                        .help("Clear shortcut")
                }
            }
            .onChange(of: focused) { _, isFocused in if !isFocused { recording = false } }
            .onChange(of: recording) { _, isRecording in
                if isRecording { startMonitor() } else { stopMonitor() }
            }
            .onAppear { if recording { startMonitor() } }
            .onDisappear { stopMonitor() }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Shortcut")
        .accessibilityValue(shortcut.map { LumenKeycap.text(for: $0) } ?? "None")
    }

    /// While recording, key presses go to the recorder before the menu bar sees them: key
    /// equivalents (⌘S, ⌘N, ⌘W) reach `performKeyEquivalent` and the main menu ahead of `keyDown`,
    /// so `.onKeyPress` never saw them and ⌘N opened a window instead of recording.
    private func startMonitor() {
        stopMonitor()
        monitor.token = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            switch Self.recorderAction(for: event) {
            case .cancel: recording = false
            case .clear: shortcut = nil; recording = false
            case .record(let recorded): shortcut = recorded; recording = false
            case .ignore: break
            }
            return nil   // swallowed while recording, so nothing else acts on it
        }
    }

    private func stopMonitor() {
        if let token = monitor.token { NSEvent.removeMonitor(token) }
        monitor.token = nil
    }

    enum RecorderAction: Equatable {
        case cancel, clear, ignore
        case record(KeyboardShortcut)

        static func == (lhs: RecorderAction, rhs: RecorderAction) -> Bool {
            switch (lhs, rhs) {
            case (.cancel, .cancel), (.clear, .clear), (.ignore, .ignore): true
            case let (.record(a), .record(b)): a.key == b.key && a.modifiers == b.modifiers
            default: false
            }
        }
    }

    /// What a key-down does while recording: Escape cancels, a bare Delete clears, a valid shortcut
    /// records, anything else (a plain letter) is ignored.
    static func recorderAction(for event: NSEvent) -> RecorderAction {
        guard let key = keyEquivalent(for: event) else { return .ignore }
        let modifiers = eventModifiers(event.modifierFlags)
        if key == .escape { return .cancel }
        if key == .delete || key == .deleteForward, modifiers.intersection([.command, .control, .option, .shift]).isEmpty { return .clear }
        return shortcut(for: key, modifiers: modifiers).map(RecorderAction.record) ?? .ignore
    }

    /// The key an AppKit key-down names, as SwiftUI spells it.
    static func keyEquivalent(for event: NSEvent) -> KeyEquivalent? {
        switch event.keyCode {
        case 53: return .escape
        case 51: return .delete
        case 117: return .deleteForward
        case 36, 76: return .return
        case 48: return .tab
        case 49: return .space
        case 123: return .leftArrow
        case 124: return .rightArrow
        case 125: return .downArrow
        case 126: return .upArrow
        case 115: return .home
        case 119: return .end
        case 116: return .pageUp
        case 121: return .pageDown
        default:
            guard let character = event.charactersIgnoringModifiers?.lowercased().first else { return nil }
            return KeyEquivalent(character)
        }
    }

    static func eventModifiers(_ flags: NSEvent.ModifierFlags) -> EventModifiers {
        var modifiers: EventModifiers = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        return modifiers
    }
}

/// Holds the recorder's event monitor across renders without triggering any.
private final class RecorderMonitor {
    var token: Any?
}

// MARK: Completion list

/// What a completion is, for its badge.
public enum LumenCompletionKind: Sendable, Hashable {
    case type, structure, `class`, function, property, variable, keyword, snippet
    case custom(String, LumenToken)

    var letter: String {
        switch self {
        case .type: "T"
        case .structure: "S"
        case .class: "C"
        case .function: "ƒ"
        case .property: "P"
        case .variable: "V"
        case .keyword: "K"
        case .snippet: "{}"
        case .custom(let letter, _): letter
        }
    }

    var token: LumenToken {
        switch self {
        case .type: .hueOrange
        case .structure: .huePink
        case .class: .hueViolet
        case .function: .hueGreen
        case .property: .hueTeal
        case .variable: .hueBlue
        case .keyword: .hueGraphite
        case .snippet: .hueYellow
        case .custom(_, let token): token
        }
    }
}

/// One completion.
public struct LumenCompletion: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    /// Its type or signature, dimmed at the trailing edge.
    public let detail: String?
    public let kind: LumenCompletionKind

    public init(id: String? = nil, _ name: String, detail: String? = nil, kind: LumenCompletionKind) {
        self.id = id ?? name
        self.name = name
        self.detail = detail
        self.kind = kind
    }
}

/// A completion popup's list: each item's kind as a lettered badge, its name with
/// the typed prefix in bold accent, and its type dimmed at the trailing edge. The selected row fills
/// with the accent. Show it in a popover or overlay at the caret; ↑/↓ and Return come from the editor.
public struct LumenCompletionList: View {
    private let items: [LumenCompletion]
    private let typed: String
    @Binding private var selection: String?
    private let maximumRows: Int
    private let onAccept: (LumenCompletion) -> Void

    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenDensity) private var density
    @Environment(\.lumenMetrics) private var metrics
    @Environment(\.lumenCodeFont) private var codeFont
    @Environment(\.lumenRendersOffscreen) private var rendersOffscreen
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.lumenStore) private var store

    public init(_ items: [LumenCompletion], typed: String, selection: Binding<String?>, maximumRows: Int = 8,
                onAccept: @escaping (LumenCompletion) -> Void) {
        self.items = items
        self.typed = typed
        _selection = selection
        self.maximumRows = maximumRows
        self.onAccept = onAccept
    }

    /// One-line rows, by density.
    private var rowHeight: CGFloat { density.rowHeight(in: metrics.layout) }

    public var body: some View {
        Group {
            if items.count <= maximumRows {
                rows
            } else if rendersOffscreen {
                rows.frame(height: CGFloat(maximumRows) * rowHeight + 6, alignment: .top).clipped()
            } else {
                ScrollViewReader { proxy in
                    ScrollView { rows }
                        .frame(height: CGFloat(maximumRows) * rowHeight + 6)
                        .onChange(of: selection) { _, id in if let id { proxy.scrollTo(id) } }
                }
            }
        }
        .frame(minWidth: 260, alignment: .leading)
        .lumenRaisedGround()
        .background(palette[.menuBackground], in: .rect(cornerRadius: metrics.radius.lg, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: metrics.radius.lg, style: .continuous).strokeBorder(palette[.borderDefault], lineWidth: metrics.stroke.hairline)
        }
        .lumenElevation(.menu)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Completions")
    }

    private var rows: some View {
        VStack(spacing: 0) {
            ForEach(items) { item in row(item).id(item.id) }
        }
        .padding(3)
    }

    private func row(_ item: LumenCompletion) -> some View {
        let selected = item.id == selection
        let prefixRange: [Range<Int>] = {
            guard !typed.isEmpty, item.name.lowercased().hasPrefix(typed.lowercased()) else { return [] }
            return [0..<typed.count]
        }()
        return Button { onAccept(item) } label: {
            HStack(spacing: metrics.spacing.s2) {
                badge(item.kind, selected: selected)
                Group {
                    if selected {
                        Text(item.name).foregroundStyle(palette[.menuHighlightForeground])
                    } else {
                        LumenHighlightedText(item.name, ranges: prefixRange, style: .emphasis).foregroundStyle(palette[.menuForeground])
                    }
                }
                .font((codeFont ?? .standard).font(sizeDelta: -0.5))
                .lineLimit(1)
                .lumenNeverTruncates(item.name)
                Spacer(minLength: metrics.spacing.s4)
                if let detail = item.detail {
                    // One line, so every row keeps one height in a transient list: a middle cut
                    // keeps the type's head and its closing generic; the whole type is in the help tag.
                    Text(detail).lineLimit(1).truncationMode(.middle)
                        .font((codeFont ?? .standard).font(sizeDelta: -1.5))
                        .foregroundStyle(palette[selected ? .menuHighlightForeground : .menuSecondaryForeground])
                        .help(detail)
                }
            }
            .padding(.horizontal, metrics.spacing.s2)
            .frame(minHeight: rowHeight)
            .background(selected ? palette[.menuHighlight] : .clear, in: .rect(cornerRadius: metrics.radius.sm, style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { if $0 { selection = item.id } }
        .accessibilityLabel([item.name, item.detail].compactMap(\.self).joined(separator: ", "))
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }

    /// The kind's letter drawn as a small icon tile, so badges follow the tiles beside them: the hue
    /// with a white letter in light, slate with the letter in its hue in dark. On the selected
    /// row it turns into the highlight's template plate, as tiles do.
    private func badge(_ kind: LumenCompletionKind, selected: Bool) -> some View {
        let colors = LumenTileColors(hue: kind.token, appearance: LumenAppearance(isDark: colorScheme == .dark, isHighContrast: contrast == .increased),
                                     store: store)
        let ink = palette[.menuHighlightForeground]
        let shape = RoundedRectangle(cornerRadius: metrics.radius.xs, style: .continuous)
        let ground: AnyShapeStyle = selected ? AnyShapeStyle(ink.opacity(LumenHighlightedTile.fill))
            : AnyShapeStyle(LinearGradient(colors: [colors.top, colors.bottom], startPoint: .top, endPoint: .bottom))
        return Text(kind.letter)
            .font(metrics.typography.countDigit)
            .foregroundStyle(selected ? ink : colors.glyph)
            .frame(width: metrics.layout.tileCompact, height: metrics.layout.tileCompact)
            .background(ground, in: shape)
            .accessibilityHidden(true)
    }
}

// MARK: Collection

/// How a collection shows its items.
public enum LumenCollectionMode: String, CaseIterable, Sendable {
    case grid, list
}

/// One item in a `LumenCollection` (a project, a document, a capture).
public struct LumenCollectionItem: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    /// Where it is, or a second line; the list's middle column.
    public let detail: String?
    public let systemImage: String
    public let hue: LumenToken
    /// When it was last used; the list's last column.
    public let date: Date?
    /// The group it's listed under, or `nil` for none.
    public let group: String?

    public init(id: String, title: String, detail: String? = nil, systemImage: String = "folder", hue: LumenToken = .hueBlue,
                date: Date? = nil, group: String? = nil) {
        self.id = id
        self.title = title
        self.detail = detail
        self.systemImage = systemImage
        self.hue = hue
        self.date = date
        self.group = group
    }
}

/// How a collection's list is sorted.
public enum LumenCollectionSort: String, CaseIterable, Sendable {
    case title, detail, date
}

/// A collection's toolbar: list and grid buttons with the grid's size slider
/// between them; the slider dims in list mode.
public struct LumenCollectionControls: View {
    @Binding private var mode: LumenCollectionMode
    @Binding private var size: Double
    private let sizes: ClosedRange<Double>

    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenMetrics) private var metrics

    public init(mode: Binding<LumenCollectionMode>, size: Binding<Double>, sizes: ClosedRange<Double> = 60...200) {
        _mode = mode
        _size = size
        self.sizes = sizes
    }

    public var body: some View {
        HStack(spacing: metrics.spacing.s2) {
            modeButton(.list, "list.bullet", "List")
            LumenSlider(value: $size, in: sizes, width: 90)
                .disabled(mode == .list)
                .help("Icon size")
                .accessibilityLabel("Icon size")
            modeButton(.grid, "square.grid.2x2", "Grid")
        }
    }

    private func modeButton(_ value: LumenCollectionMode, _ symbol: String, _ title: String) -> some View {
        Button { mode = value } label: {
            LumenSymbol(symbol)
        }
        .buttonStyle(.lumenPanelIcon(isOn: mode == value))
        .lumenIconOnlyControl(title)
        .help(title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(mode == value ? [.isSelected, .isButton] : .isButton)
    }
}

/// Items as a grid of tiles that grow with `size`, or a list sortable by its column headers.
/// Groups collapse under disclosure headers in both. Double-click opens.
public struct LumenCollection: View {
    private let items: [LumenCollectionItem]
    private let mode: LumenCollectionMode
    private let size: Double
    @Binding private var selection: String?
    @Binding private var sort: LumenCollectionSort
    private let onOpen: (LumenCollectionItem) -> Void

    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenDensity) private var density
    @Environment(\.lumenMetrics) private var metrics
    @State private var collapsed: Set<String> = []
    @Environment(\.lumenEmptyMessage) private var emptyMessage

    public init(_ items: [LumenCollectionItem], mode: LumenCollectionMode, size: Double = 120, selection: Binding<String?>,
                sort: Binding<LumenCollectionSort>, onOpen: @escaping (LumenCollectionItem) -> Void) {
        self.items = items
        self.mode = mode
        self.size = size
        _selection = selection
        _sort = sort
        self.onOpen = onOpen
    }

    /// Items sorted for the list: by title or detail alphabetically, or by date newest first.
    static func sorted(_ items: [LumenCollectionItem], by sort: LumenCollectionSort) -> [LumenCollectionItem] {
        switch sort {
        case .title: items.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .detail: items.sorted { ($0.detail ?? "").localizedStandardCompare($1.detail ?? "") == .orderedAscending }
        case .date: items.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        }
    }

    /// Groups in first-appearance order, ungrouped items first under an empty title.
    static func grouped(_ items: [LumenCollectionItem]) -> [(String, [LumenCollectionItem])] {
        var order: [String] = []
        var byGroup: [String: [LumenCollectionItem]] = [:]
        for item in items {
            let key = item.group ?? ""
            if byGroup[key] == nil { order.append(key) }
            byGroup[key, default: []].append(item)
        }
        let sortedOrder = order.filter(\.isEmpty) + order.filter { !$0.isEmpty }
        return sortedOrder.map { ($0, byGroup[$0] ?? []) }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: metrics.spacing.s2) {
            if mode == .list { header }
            if items.isEmpty { LumenEmptyState.inline(emptyMessage ?? "Nothing here yet") }
            ForEach(Self.grouped(mode == .list ? Self.sorted(items, by: sort) : items), id: \.0) { group, members in
                if !group.isEmpty { groupHeader(group, count: members.count) }
                if !collapsed.contains(group) {
                    if mode == .grid {
                        // Top-aligned, so a title that wraps to two lines runs downward and the tiles
                        // in a row stay on one line.
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: size), spacing: metrics.spacing.s3, alignment: .top)],
                                  spacing: metrics.spacing.s4) {
                            ForEach(members) { tile($0) }
                        }
                    } else {
                        VStack(spacing: 0) { ForEach(members) { row($0) } }
                    }
                }
            }
        }
        .padding(metrics.spacing.s3)
    }

    private func groupHeader(_ title: String, count: Int) -> some View {
        let open = !collapsed.contains(title)
        return Button {
            if open { collapsed.insert(title) } else { collapsed.remove(title) }
        } label: {
            HStack(spacing: metrics.spacing.s2) {
                LumenSymbol("chevron.right").font(.system(size: metrics.layout.disclosureGlyph, weight: .bold)).foregroundStyle(palette[.fgTertiary]).rotationEffect(.degrees(open ? 90 : 0))
                Text(title).font(metrics.typography.captionEmphasized).foregroundStyle(palette[.fgSecondary])
                LumenCount(count)
                Spacer(minLength: 0)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .padding(.top, metrics.spacing.s2)
        .accessibilityValue(open ? "Expanded" : "Collapsed")
    }

    private func tile(_ item: LumenCollectionItem) -> some View {
        let selected = item.id == selection
        return VStack(spacing: metrics.spacing.s2) {
            LumenIconTile(item.systemImage, hue: item.hue, size: CGFloat(size) * 0.5)
            Text(item.title).font(metrics.typography.caption).foregroundStyle(palette[selected ? .menuHighlightForeground : .fgPrimary])
                .lineLimit(2).multilineTextAlignment(.center)
                .help(item.title)
                .padding(.horizontal, metrics.spacing.s3).padding(.vertical, metrics.spacing.s1)
                .background(selected ? palette[.menuHighlight] : .clear, in: .rect(cornerRadius: metrics.radius.sm, style: .continuous))
        }
        .frame(width: CGFloat(size))
        .contentShape(.rect)
        .lumenSelectAndOpen(select: { selection = item.id }, open: { onOpen(item) })
        .help(item.detail ?? item.title)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }

    private var header: some View {
        CollectionColumns(gutter: metrics.spacing.s3) {
            sortHeader("Name", .title).frame(maxWidth: .infinity, alignment: .leading)
            sortHeader("Location", .detail).frame(maxWidth: .infinity, alignment: .leading)
            sortHeader("Last Opened", .date).frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, metrics.spacing.s2)
        .frame(height: metrics.layout.subheaderHeight)
        .overlay(alignment: .bottom) { Rectangle().fill(palette[.borderSubtle]).frame(height: metrics.stroke.hairline) }
    }

    private func sortHeader(_ title: String, _ key: LumenCollectionSort) -> some View {
        Button { sort = key } label: {
            HStack(spacing: metrics.spacing.s2) {
                // Table column headers share the one section-label style (capitals, tracked), as
                // LumenTable's do; the sorted column reads stronger.
                Text(title).lumenSectionLabel(sort == key ? .fgPrimary : .fgTertiary)
                if sort == key { LumenSymbol(key == .date ? "chevron.down" : "chevron.up").font(.system(size: metrics.layout.disclosureGlyph, weight: .bold)) }
            }
            .foregroundStyle(palette[sort == key ? .fgPrimary : .fgTertiary])
        }
        .buttonStyle(.lumenBare)
        .help("Sort by \(title.lowercased())")
    }

    private func row(_ item: LumenCollectionItem) -> some View {
        let selected = item.id == selection
        let foreground: LumenToken = selected ? .menuHighlightForeground : .fgPrimary
        return CollectionColumns(gutter: metrics.spacing.s3) {
            HStack(spacing: metrics.spacing.s2) {
                LumenRowTile(systemImage: item.systemImage, hue: item.hue, size: metrics.layout.tileCompact, isHighlighted: selected)
                Text(item.title).font(metrics.typography.callout).foregroundStyle(palette[foreground]).lineLimit(1)
                    .lumenNeverTruncates(item.title)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(item.detail ?? "").font(metrics.typography.caption).foregroundStyle(palette[selected ? .menuHighlightForeground : .fgTertiary])
                .lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
            Text(item.date.map { $0.formatted(.relative(presentation: .named)) } ?? "—")
                .font(metrics.typography.caption).foregroundStyle(palette[selected ? .menuHighlightForeground : .fgTertiary])
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, metrics.spacing.s2)
        .frame(height: density.rowHeight(in: metrics.layout))
        .background(selected ? palette[.menuHighlight] : .clear, in: .rect(cornerRadius: metrics.radius.sm, style: .continuous))
        .contentShape(.rect)
        .lumenSelectAndOpen(select: { selection = item.id }, open: { onOpen(item) })
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }
}

extension View {
    /// Click selects at once; a double-click also opens. `.onTapGesture(count: 2)` before a single
    /// tap made every single click wait out the double-click interval; the double tap runs
    /// alongside instead, so the first click of a double-click selects and the second opens.
    func lumenSelectAndOpen(select: @escaping () -> Void, open: @escaping () -> Void) -> some View {
        onTapGesture(perform: select)
            .simultaneousGesture(TapGesture(count: 2).onEnded { select(); open() })
    }
}

/// The list's three columns, shared by the header and every row so they line up: the name takes the
/// larger share (titles are the longest and never shorten), the location the rest (it truncates in
/// the middle), and the date a fixed width, with a gutter between each so neighbors never touch.
private struct CollectionColumns: Layout {
    var gutter: CGFloat
    var dateWidth: CGFloat = 96
    var nameShare: CGFloat = 0.56

    private func widths(for total: CGFloat) -> [CGFloat] {
        let flexible = max(0, total - dateWidth - gutter * 2)
        let name = (flexible * nameShare).rounded()
        return [name, flexible - name, dateWidth]
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        // Never narrower than the name column needs for its title at its share (titles never shorten).
        let nameIdeal = subviews.first?.sizeThatFits(.unspecified).width ?? 0
        let minimum = (nameIdeal / nameShare).rounded(.up) + dateWidth + gutter * 2
        let width = max(proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? minimum, minimum)
        let columns = widths(for: width)
        let height = zip(subviews, columns).map { $0.sizeThatFits(ProposedViewSize(width: $1, height: proposal.height)).height }.max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        for (subview, width) in zip(subviews, widths(for: bounds.width)) {
            subview.place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(width: width, height: bounds.height))
            x += width + gutter
        }
    }
}

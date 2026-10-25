import AppKit
import SwiftUI
import LumenTokens

// MARK: Keycap

/// A keyboard shortcut drawn as keycaps (⌘ ⇧ K), for custom panels and help text. Native menus
/// draw their own shortcuts; use this where the system doesn't.
public struct LumenKeycap: View {
    private let keys: [String]
    private let onHighlight: Bool

    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenMetrics) private var metrics

    /// - Parameter keys: each key as it should read, in order: `["⌘", "⇧", "K"]`.
    public init(_ keys: [String], onHighlight: Bool = false) {
        self.keys = keys
        self.onHighlight = onHighlight
    }

    /// The keys of a SwiftUI shortcut, in the system's modifier order (⌃ ⌥ ⇧ ⌘).
    public init(_ shortcut: KeyboardShortcut, onHighlight: Bool = false) {
        self.init(Self.keys(for: shortcut), onHighlight: onHighlight)
    }

    nonisolated static func keys(for shortcut: KeyboardShortcut) -> [String] {
        var keys: [String] = []
        if shortcut.modifiers.contains(.control) { keys.append("⌃") }
        if shortcut.modifiers.contains(.option) { keys.append("⌥") }
        if shortcut.modifiers.contains(.shift) { keys.append("⇧") }
        if shortcut.modifiers.contains(.command) { keys.append("⌘") }
        keys.append(name(of: shortcut.key))
        return keys
    }

    /// The shortcut as one string (⇧⌘K), for help tags and messages.
    public nonisolated static func text(for shortcut: KeyboardShortcut) -> String {
        keys(for: shortcut).joined()
    }

    nonisolated static func name(of key: KeyEquivalent) -> String {
        switch key {
        case .return: return "↩"
        case .delete: return "⌫"
        case .deleteForward: return "⌦"
        case .escape: return "⎋"
        case .tab: return "⇥"
        case .space: return "Space"
        case .upArrow: return "↑"
        case .downArrow: return "↓"
        case .leftArrow: return "←"
        case .rightArrow: return "→"
        case .home: return "↖"
        case .end: return "↘"
        case .pageUp: return "⇞"
        case .pageDown: return "⇟"
        case .clear: return "⌧"
        default:
            // Function keys arrive as AppKit's private-use characters (NSF1FunctionKey = U+F704 …).
            if let scalar = key.character.unicodeScalars.first, (0xF704...0xF726).contains(scalar.value) {
                return "F\(scalar.value - 0xF703)"
            }
            return String(key.character).uppercased()
        }
    }

    /// Every key is this tall, so word keys ("esc", "Space") and glyph keys share one cap.
    static let height: CGFloat = 16
    /// The fill of a key on the filled highlight: a light plate of the highlight's foreground, kept
    /// faint so the key's text keeps its contrast on the highlight.
    static let highlightFill = 0.10
    static let highlightEdge = 0.35

    /// Glyphs that sit high in their em box (↩'s hook, ⌃'s caret), lowered to the cap's optical
    /// middle. Measured on the keycaps golden: 1.25–1.75 pt high.
    nonisolated static func opticalDrop(for key: String) -> CGFloat {
        ["↩", "⌃", "⌅"].contains(key) ? 1.5 : 0
    }

    public var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                Text(key)
                    .font(metrics.typography.caption.weight(.medium))
                    .offset(y: Self.opticalDrop(for: key))
                    .foregroundStyle(onHighlight ? palette[.menuHighlightForeground] : palette[.keycapForeground])
                    .fixedSize()
                    // Word keys get real side room; one-glyph keys are square.
                    .padding(.horizontal, key.count > 1 ? metrics.spacing.s2 : 0)
                    .frame(minWidth: Self.height, minHeight: Self.height, maxHeight: Self.height)
                    .background(onHighlight ? palette[.menuHighlightForeground].opacity(Self.highlightFill) : palette[.keycapBackground],
                                in: .rect(cornerRadius: metrics.radius.xs))
                    .overlay {
                        // A hairline edge inside the cap, so a key reads as a key on any ground
                        // (light caps vanished on white) and every appearance keeps one size.
                        RoundedRectangle(cornerRadius: metrics.radius.xs)
                            .strokeBorder(onHighlight ? palette[.menuHighlightForeground].opacity(Self.highlightEdge) : palette[.borderDefault],
                                          lineWidth: metrics.stroke.hairline)
                    }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(keys.joined(separator: " "))
    }
}

// MARK: Highlighted tile

/// An icon tile on the filled highlight (a highlighted menu or palette row, a selected picker row):
/// the symbol in the highlight's foreground on a faint plate of it, as macOS turns highlighted menu
/// icons into templates. One look in every hue, theme and appearance, so a highlighted row never
/// switches tile styles (slate in dark, hue in light) or puts an orange tile on the violet fill. It
/// keeps the tile's size and shape, so nothing moves when the highlight arrives.
struct LumenHighlightedTile: View {
    let systemImage: String
    let size: CGFloat
    /// The foreground of the fill it sits on: `menu.highlightForeground`, or
    /// `accent.filledForeground` on a filled-accent selection (pickers).
    var foreground: LumenToken = .menuHighlightForeground

    @Environment(\.lumenPalette) private var palette

    static let fill = 0.18
    static let edge = 0.30

    var body: some View {
        let ink = palette[foreground]
        let shape = RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
        Group {
            if let image = LumenGlyph.symbolImage(for: LumenIconTile.tileSymbol(for: systemImage), filled: true) {
                image
                    .resizable()
                    .scaledToFit()
                    .font(.system(size: size, weight: .medium))
                    .symbolRenderingMode(.monochrome)
                    .symbolVariant(.fill)
                    .frame(width: size * LumenIconTile.symbolShare, height: size * LumenIconTile.symbolShare)
            } else if let glyph = LumenGlyph.named(systemImage) {
                LumenGlyphView(glyph, size: size * LumenIconTile.symbolShare, weight: size <= 28 ? .bold : .regular)
                    .environment(\.lumenGlyphTint, .clear)
            }
        }
        .foregroundStyle(ink)
        .frame(width: size, height: size)
        .background(ink.opacity(Self.fill), in: shape)
        .overlay { shape.strokeBorder(ink.opacity(Self.edge), lineWidth: max(0.5, size / 56)) }
        .accessibilityHidden(true)
    }
}

/// An icon tile that turns into `LumenHighlightedTile` on the filled highlight.
struct LumenRowTile: View {
    let systemImage: String
    let hue: LumenToken
    let size: CGFloat
    let isHighlighted: Bool
    var foreground: LumenToken = .menuHighlightForeground

    var body: some View {
        if isHighlighted {
            LumenHighlightedTile(systemImage: systemImage, size: size, foreground: foreground)
        } else {
            LumenIconTile(systemImage, hue: hue, size: size)
        }
    }
}

// MARK: Command menu

/// One line of a command menu: an item, a section label or a separator.
public struct LumenMenuEntry: Identifiable, Sendable {
    public enum Kind: Sendable {
        case item(LumenMenuItem)
        case section(String)
        case separator
    }

    public let id: String
    public let kind: Kind

    public static func section(_ title: String) -> LumenMenuEntry { .init(id: "section:\(title)", kind: .section(title)) }

    /// A separator. Its id is stable by default, so a menu built in a `body` keeps its highlight and
    /// open submenus when its parent re-renders (a fresh UUID each time reset them).
    public static func separator(_ id: String? = nil) -> LumenMenuEntry { .init(id: "separator:\(id ?? "")", kind: .separator) }

    /// - Parameter id: tells apart two items with one title (two "Open"s in different sections);
    ///   the title by default.
    public static func item(id: String? = nil, _ title: String, subtitle: String? = nil, systemImage: String? = nil,
                            hue: LumenToken? = nil, shortcut: KeyboardShortcut? = nil, isChecked: Bool = false,
                            isDestructive: Bool = false, isEnabled: Bool = true,
                            action: @escaping @MainActor @Sendable () -> Void = {}) -> LumenMenuEntry {
        .init(id: "item:\(id ?? title)", kind: .item(LumenMenuItem(title: title, subtitle: subtitle, systemImage: systemImage, hue: hue,
                                                                    shortcut: shortcut, isChecked: isChecked, isDestructive: isDestructive,
                                                                    isEnabled: isEnabled, children: [], action: action)))
    }

    public static func submenu(id: String? = nil, _ title: String, systemImage: String? = nil, hue: LumenToken? = nil,
                               _ children: [LumenMenuEntry]) -> LumenMenuEntry {
        .init(id: "submenu:\(id ?? title)", kind: .item(LumenMenuItem(title: title, subtitle: nil, systemImage: systemImage, hue: hue,
                                                                 shortcut: nil, isChecked: false, isDestructive: false,
                                                                 isEnabled: true, children: children, action: {})))
    }

    var item: LumenMenuItem? { if case .item(let item) = kind { item } else { nil } }
}

public struct LumenMenuItem: Sendable {
    public var title: String
    public var subtitle: String?
    public var systemImage: String?
    public var hue: LumenToken?
    public var shortcut: KeyboardShortcut?
    public var isChecked: Bool
    public var isDestructive: Bool
    public var isEnabled: Bool
    public var children: [LumenMenuEntry]
    public var action: @MainActor @Sendable () -> Void

    var hasSubmenu: Bool { !children.isEmpty }
}

/// A command menu: Lumen's one custom menu surface, for quick actions and command palettes
/// (opened from a toolbar button or a shortcut), where a native menu can't show subtitles or
/// search. Menu-bar and context menus stay native (see `LumenMenuLabel`).
///
/// It behaves like a Mac menu: the highlight follows the pointer and the arrow keys, → opens a
/// submenu and ← closes it, ↩ chooses, ⎋ dismisses. Items show icon tiles, subtitles, keycaps,
/// checkmarks, and a destructive tone. Standalone, submenus open to the trailing side; in a
/// popover (`.lumenCommandMenu`), which can't draw past its edge, they open in place with a back row.
public struct LumenCommandMenu: View {
    /// Where submenus appear.
    enum SubmenuPlacement { case trailing, inPlace }

    public let entries: [LumenMenuEntry]
    private let onDismiss: @MainActor () -> Void
    private let width: CGFloat
    private let placement: SubmenuPlacement

    /// The submenu items opened with → or a click, outermost first; the keyboard works in the last.
    @State private var opened: [Int] = []
    /// The highlighted row in the innermost open list.
    @State private var highlighted: Int?
    /// A submenu shown because the pointer rests on its item, not yet entered.
    @State private var peek: Int?
    @FocusState private var focused: Bool

    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenMetrics) private var metrics
    @Environment(\.lumenDensity) private var density

    public init(_ entries: [LumenMenuEntry], width: CGFloat = 320, onDismiss: @escaping @MainActor () -> Void = {}) {
        self.init(entries, width: width, placement: .trailing, onDismiss: onDismiss)
    }

    init(_ entries: [LumenMenuEntry], width: CGFloat, placement: SubmenuPlacement, onDismiss: @escaping @MainActor () -> Void) {
        self.entries = entries
        self.width = width
        self.placement = placement
        self.onDismiss = onDismiss
    }

    /// For previews and golden images: a fixed highlight and open submenu.
    init(_ entries: [LumenMenuEntry], width: CGFloat = 280, highlighted: Int?, openSubmenu: Int?) {
        self.init(entries, width: width, placement: .trailing, onDismiss: {})
        _highlighted = State(initialValue: highlighted)
        _peek = State(initialValue: openSubmenu)
    }

    /// The entries of the list at `depth`: the root, then each opened submenu's children, then
    /// the peeked one's.
    private func list(at depth: Int) -> [LumenMenuEntry] {
        var list = entries
        for index in (opened + (peek.map { [$0] } ?? [])).prefix(depth) {
            guard list.indices.contains(index), let item = list[index].item else { return [] }
            list = item.children
        }
        return list
    }

    private var activeList: [LumenMenuEntry] { list(at: opened.count) }

    public var body: some View {
        Group {
            switch placement {
            case .trailing: level(0)
            case .inPlace: inPlaceLevel
            }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true }
        .onChange(of: entries.map(\.id)) { opened = []; highlighted = nil; peek = nil }
        .onKeyPress(.downArrow) { move(1); return .handled }
        .onKeyPress(.upArrow) { move(-1); return .handled }
        .onKeyPress(.rightArrow) {
            if let highlighted { enter(highlighted) }
            return .handled
        }
        .onKeyPress(.leftArrow) { back(); return .handled }
        .onKeyPress(.return) {
            if let highlighted { choose(highlighted, depth: opened.count) }
            return .handled
        }
        .onKeyPress(.escape) { onDismiss(); return .handled }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }

    /// One list and, to its trailing side, the submenu open from it.
    private func level(_ depth: Int) -> AnyView {
        let rows = list(at: depth)
        let icons = Self.hasIcons(rows)
        let rowHighlight = depth < opened.count ? opened[depth] : depth == opened.count ? highlighted : nil
        let open = depth < opened.count ? opened[depth] : depth == opened.count ? peek : nil
        return AnyView(panel(width: depth == 0 ? width : submenuWidth) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, entry in
                line(entry, index: index, depth: depth, highlighted: rowHighlight == index, iconColumn: icons)
                    .overlay(alignment: .topTrailing) {
                        if open == index, entry.item?.hasSubmenu == true {
                            // Anchored at the row's trailing edge; the submenu starts just past it, as in macOS.
                            level(depth + 1)
                                .frame(width: 0, alignment: .topLeading)
                                .offset(x: metrics.spacing.s3 + metrics.spacing.s2, y: -metrics.spacing.s2)
                                .transition(.opacity)
                        }
                    }
                    .zIndex(open == index ? 1 : 0)
            }
        })
    }

    /// The innermost open list, under a row that goes back to its parent.
    private var inPlaceLevel: some View {
        let depth = opened.count
        let icons = Self.hasIcons(activeList)
        return panel(width: width) {
            if let parent = opened.last, let title = list(at: depth - 1)[safe: parent]?.item?.title {
                Button(action: back) {
                    HStack(spacing: metrics.spacing.s2) {
                        LumenSymbol("chevron.left").font(.system(size: metrics.iconSize.xsmall, weight: .semibold))
                        Text(title).font(metrics.typography.body.weight(.semibold))
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(palette[.menuSecondaryForeground])
                    .padding(.horizontal, metrics.spacing.s3)
                    .frame(minHeight: metrics.layout.rowHeightCompact)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back to \(title)")
                Rectangle().fill(palette[.menuSeparator]).frame(height: metrics.stroke.hairline)
                    .padding(.horizontal, metrics.spacing.s4).padding(.vertical, metrics.spacing.s1)
            }
            ForEach(Array(activeList.enumerated()), id: \.offset) { index, entry in
                line(entry, index: index, depth: depth, highlighted: highlighted == index, iconColumn: icons)
            }
        }
    }

    private var submenuWidth: CGFloat { max(200, width - 40) }

    private func panel<Content: View>(width: CGFloat, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 1, content: content)
            .padding(metrics.spacing.s2)
            .frame(width: width, alignment: .leading)
            .lumenRaisedGround()
            .background(palette[.menuBackground], in: .rect(cornerRadius: metrics.radius.lg, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: metrics.radius.lg, style: .continuous)
                    .strokeBorder(palette[.menuSeparator], lineWidth: metrics.stroke.hairline)
            }
            .lumenElevation(.menu)
    }

    @ViewBuilder
    private func line(_ entry: LumenMenuEntry, index: Int, depth: Int, highlighted: Bool, iconColumn: Bool) -> some View {
        switch entry.kind {
        case .section(let title):
            Text(title)
                .lumenSectionLabel(.menuSecondaryForeground)
                .padding(.horizontal, metrics.spacing.s4)
                .padding(.top, index == 0 ? metrics.spacing.s1 : metrics.spacing.s3)
                .padding(.bottom, metrics.spacing.s1)
                .accessibilityAddTraits(.isHeader)
        case .separator:
            Rectangle().fill(palette[.menuSeparator]).frame(height: metrics.stroke.hairline)
                .padding(.horizontal, metrics.spacing.s4).padding(.vertical, metrics.spacing.s2)
        case .item(let item):
            row(item, index: index, depth: depth, isHighlighted: highlighted && item.isEnabled, iconColumn: iconColumn)
        }
    }

    /// Whether any item in a list shows an icon: then every item keeps the icon column, so titles
    /// line up as in a native menu.
    static func hasIcons(_ entries: [LumenMenuEntry]) -> Bool { entries.contains { $0.item?.systemImage != nil } }

    private func row(_ item: LumenMenuItem, index: Int, depth: Int, isHighlighted: Bool, iconColumn: Bool) -> some View {
        let foreground = !item.isEnabled ? palette[.fgDisabled]
            : isHighlighted ? palette[.menuHighlightForeground]
            : item.isDestructive ? palette[.menuDestructive] : palette[.menuForeground]
        return HStack(spacing: metrics.spacing.s3) {
            LumenSymbol("checkmark")
                .font(.system(size: metrics.iconSize.xsmall, weight: .semibold))
                .opacity(item.isChecked ? 1 : 0)
                .frame(width: metrics.iconSize.small)
                .accessibilityHidden(!item.isChecked)
            if let systemImage = item.systemImage {
                if let hue = item.hue {
                    // One tile size per menu, a two-line item's too; disabled items fade their
                    // tile with their text, as the palette does. On the highlight the tile turns
                    // into the highlight's template plate (one look for every hue).
                    LumenRowTile(systemImage: systemImage, hue: hue, size: metrics.layout.tileMenu, isHighlighted: isHighlighted)
                        .opacity(item.isEnabled ? 1 : metrics.layout.disabledOpacity)
                } else {
                    LumenSymbol(systemImage).frame(width: metrics.layout.tileMenu)
                }
            } else if iconColumn {
                Color.clear.frame(width: metrics.layout.tileMenu, height: 1).accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(item.title).font(metrics.typography.body)
                if let subtitle = item.subtitle {
                    // Full strength on the highlight: dimmed white fell under 4.5:1 there.
                    Text(subtitle).font(metrics.typography.caption).lineLimit(1).truncationMode(.tail).help(subtitle)
                        .foregroundStyle(isHighlighted ? palette[.menuHighlightForeground] : palette[.menuSecondaryForeground])
                }
            }
            Spacer(minLength: metrics.spacing.s4)
            if item.hasSubmenu {
                LumenSymbol("chevron.right").font(.system(size: metrics.iconSize.xsmall, weight: .semibold))
            } else if let shortcut = item.shortcut {
                LumenKeycap(shortcut, onHighlight: isHighlighted)
            }
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, metrics.spacing.s3)
        .frame(minHeight: item.subtitle == nil ? density.rowHeight(in: metrics.layout) : density.detailedRowHeight(in: metrics.layout))
        .background(isHighlighted ? palette[.menuHighlight] : .clear, in: .rect(cornerRadius: metrics.radius.sm, style: .continuous))
        .contentShape(.rect)
        .onHover { hovering in
            if hovering {
                guard item.isEnabled else { return }
                hover(index, depth: depth, opensSubmenu: item.hasSubmenu)
            } else {
                unhover(index, depth: depth)
            }
        }
        .onTapGesture { choose(index, depth: depth) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel([item.title, item.subtitle].compactMap(\.self).joined(separator: ", "))
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(item.isChecked ? "Checked" : "")
        .accessibilityHint(item.hasSubmenu ? "Opens a submenu" : "")
    }

    /// The pointer makes the list it rests in the active one, as in a native menu.
    private func hover(_ index: Int, depth: Int, opensSubmenu: Bool) {
        if depth == opened.count + 1, let peek { opened.append(peek) }
        guard depth <= opened.count else { return }
        opened = Array(opened.prefix(depth))
        highlighted = index
        peek = opensSubmenu && placement == .trailing ? index : nil
    }

    /// The pointer left a row: its highlight goes, as in a native menu, unless the row's submenu is
    /// showing (the pointer is on its way there) or another row already took the highlight.
    private func unhover(_ index: Int, depth: Int) {
        guard depth == opened.count, highlighted == index, peek != index else { return }
        highlighted = nil
    }

    private func move(_ step: Int) {
        let list = activeList
        let order = list.indices.filter { list[$0].item?.isEnabled == true }
        guard !order.isEmpty else { return }
        let current = highlighted.flatMap { order.firstIndex(of: $0) } ?? (step > 0 ? -1 : order.count)
        highlighted = order[(current + step + order.count) % order.count]
        peek = nil
    }

    /// Opens the submenu of the highlighted item and moves the keyboard into it.
    private func enter(_ index: Int) {
        guard let item = activeList[safe: index]?.item, item.isEnabled, item.hasSubmenu else { return }
        opened.append(index)
        highlighted = item.children.indices.first { item.children[$0].item?.isEnabled == true }
        peek = nil
    }

    private func back() {
        guard let parent = opened.popLast() else { return }
        highlighted = parent
        peek = nil
    }

    private func choose(_ index: Int, depth: Int) {
        guard depth <= opened.count else { return }
        opened = Array(opened.prefix(depth))
        guard let item = activeList[safe: index]?.item, item.isEnabled else { return }
        highlighted = index
        if item.hasSubmenu {
            enter(index)
        } else {
            item.action()
            onDismiss()
        }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

public extension View {
    /// Presents a command menu in a popover from this view (a toolbar button, a field).
    func lumenCommandMenu(isPresented: Binding<Bool>, entries: [LumenMenuEntry]) -> some View {
        popover(isPresented: isPresented, arrowEdge: .bottom) {
            LumenCommandMenu(entries, width: 320, placement: .inPlace) { isPresented.wrappedValue = false }
                .padding(8)
        }
    }
}

import AppKit
import SwiftUI
import LumenTokens

// A tab overview, a checklist tree and commit composer, a font picker, a
// code sample block and status row, card carousels and an item detail header.

// MARK: Tab overview

/// One tab in a `LumenTabOverview`.
public struct LumenOverviewTab: Identifiable {
    public let id: String
    public let title: String
    public let systemImage: String
    public let hue: LumenToken
    public let isPinned: Bool
    /// A miniature of the tab's content.
    public let preview: AnyView

    public init<Preview: View>(id: String, title: String, systemImage: String, hue: LumenToken = .fgSecondary, isPinned: Bool = false,
                               @ViewBuilder preview: () -> Preview) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.hue = hue
        self.isPinned = isPinned
        self.preview = AnyView(preview())
    }
}

/// Every open tab as a thumbnail: a grid of previews with each title under its
/// card, shortened in the middle; the current tab ringed in the accent. Click one to switch.
public struct LumenTabOverview: View {
    private let tabs: [LumenOverviewTab]
    private let selection: String?
    private let thumbnailWidth: CGFloat
    private let onSelect: (String) -> Void

    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenMetrics) private var metrics
    @State private var hovered: String?

    public init(_ tabs: [LumenOverviewTab], selection: String?, thumbnailWidth: CGFloat = 200, onSelect: @escaping (String) -> Void) {
        self.tabs = tabs
        self.selection = selection
        self.thumbnailWidth = thumbnailWidth
        self.onSelect = onSelect
    }

    public var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: thumbnailWidth), spacing: metrics.spacing.s6)], spacing: metrics.spacing.s6) {
            ForEach(tabs) { tab in card(tab) }
        }
        .padding(metrics.spacing.s6)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("All tabs")
    }

    private func card(_ tab: LumenOverviewTab) -> some View {
        let selected = tab.id == selection
        return Button { onSelect(tab.id) } label: {
            VStack(spacing: metrics.spacing.s2) {
                tab.preview
                    .allowsHitTesting(false)
                    .frame(width: thumbnailWidth, height: thumbnailWidth * 0.65, alignment: .topLeading)
                    .clipShape(.rect(cornerRadius: metrics.radius.md, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: metrics.radius.md, style: .continuous)
                            .strokeBorder(palette[selected ? .accent : hovered == tab.id ? .borderStrong : .borderDefault],
                                          lineWidth: selected ? metrics.stroke.focus : metrics.stroke.hairline)
                    }
                HStack(spacing: metrics.spacing.s1) {
                    if tab.isPinned { LumenSymbol("pin.fill").font(.system(size: metrics.iconSize.micro)).foregroundStyle(palette[.fgTertiary]) }
                    LumenSymbol(tab.systemImage).foregroundStyle(palette[tab.hue])
                    Text(tab.title).font(metrics.typography.caption.weight(selected ? .semibold : .regular))
                        .foregroundStyle(palette[selected ? .fgPrimary : .fgSecondary]).lineLimit(1).truncationMode(.middle)
                        .help(tab.title)
                }
                .frame(maxWidth: thumbnailWidth)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 ? tab.id : (hovered == tab.id ? nil : hovered) }
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }
}

// MARK: Checklist tree

/// A checkbox's state, mixed when a folder's children differ.
public enum LumenCheckState: Sendable, Hashable {
    case on, off, mixed
}

/// One row of a checklist tree (a changed file or its folder).
public struct LumenChecklistNode: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let systemImage: String
    public let hue: LumenToken
    public let depth: Int
    /// A status glyph at the trailing edge ("?" untracked, "M" modified, "A" added).
    public let status: String?
    public let statusTone: LumenToken

    public init(id: String, title: String, systemImage: String = "doc", hue: LumenToken = .fgSecondary, depth: Int = 0,
                status: String? = nil, statusTone: LumenToken = .fgTertiary) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.hue = hue
        self.depth = depth
        self.status = status
        self.statusTone = statusTone
    }
}

/// A tree of checkboxes: each folder's box mixed when only some of its files are
/// checked; checking a folder checks everything under it. `checked` holds the leaves' ids.
public struct LumenChecklistTree: View {
    private let nodes: [LumenChecklistNode]
    @Binding private var checked: Set<String>
    @Binding private var selection: String?

    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenMetrics) private var metrics

    /// - Parameter nodes: in document order; a node's children follow it, one level deeper.
    public init(_ nodes: [LumenChecklistNode], checked: Binding<Set<String>>, selection: Binding<String?>) {
        self.nodes = nodes
        _checked = checked
        _selection = selection
    }

    /// The leaves under the node at `index` (itself when it has no children).
    static func leaves(under index: Int, in nodes: [LumenChecklistNode]) -> [String] {
        let depth = nodes[index].depth
        var result: [String] = []
        var cursor = index + 1
        while cursor < nodes.count, nodes[cursor].depth > depth {
            let isLeaf = cursor + 1 >= nodes.count || nodes[cursor + 1].depth <= nodes[cursor].depth
            if isLeaf { result.append(nodes[cursor].id) }
            cursor += 1
        }
        return result.isEmpty ? [nodes[index].id] : result
    }

    /// A node's state from its leaves: on, off, or mixed.
    static func state(of index: Int, in nodes: [LumenChecklistNode], checked: Set<String>) -> LumenCheckState {
        let leaves = leaves(under: index, in: nodes)
        let count = leaves.filter(checked.contains).count
        return count == 0 ? .off : count == leaves.count ? .on : .mixed
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(nodes.enumerated()), id: \.element.id) { index, node in row(node, index: index) }
        }
        .accessibilityElement(children: .contain)
    }

    private func row(_ node: LumenChecklistNode, index: Int) -> some View {
        let state = Self.state(of: index, in: nodes, checked: checked)
        let selected = node.id == selection
        return HStack(spacing: metrics.spacing.s2) {
            Button {
                let leaves = Self.leaves(under: index, in: nodes)
                if state == .on { checked.subtract(leaves) } else { checked.formUnion(leaves) }
            } label: {
                checkbox(state)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Include \(node.title)")
            .accessibilityValue(state == .on ? "On" : state == .off ? "Off" : "Some")
            LumenSymbol(node.systemImage).foregroundStyle(palette[node.hue])
            LumenSemanticText(node.title, kind: LumenSemanticTextPolicy.labelKind(for: node.title)).font(metrics.typography.callout).foregroundStyle(palette[.fgPrimary])
            Spacer(minLength: metrics.spacing.s2)
            if let status = node.status {
                Text(status).font(metrics.typography.countDigit).foregroundStyle(palette[node.statusTone])
                    .frame(width: 16, height: 16)
                    .overlay { RoundedRectangle(cornerRadius: metrics.radius.xs, style: .continuous).strokeBorder(palette[node.statusTone].opacity(0.6), lineWidth: metrics.stroke.hairline) }
            }
        }
        .padding(.leading, CGFloat(node.depth) * 18 + metrics.spacing.s2)
        .padding(.trailing, metrics.spacing.s2)
        .frame(minHeight: metrics.layout.minimumHitTarget)
        .background(selected ? palette[.sidebarRowSelected] : .clear, in: .rect(cornerRadius: metrics.radius.sm, style: .continuous))
        .contentShape(.rect)
        .onTapGesture { selection = node.id }
    }

    private func checkbox(_ state: LumenCheckState) -> some View {
        LumenCheckboxBox(state: state == .on ? true : state == .off ? false : nil)
    }
}

// MARK: Commit composer

/// Writing a commit: the message with its hint, a character count against a
/// soft limit for the first line, Amend, the author's avatar and Commit. ⌘Return commits.
public struct LumenCommitComposer: View {
    @Binding private var message: String
    @Binding private var amends: Bool
    private let author: String
    private let summaryLimit: Int
    private let canCommit: Bool
    private let onCommit: () -> Void

    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenMetrics) private var metrics
    @Environment(\.lumenRendersOffscreen) private var rendersOffscreen

    public init(message: Binding<String>, amends: Binding<Bool>, author: String, summaryLimit: Int = 50, canCommit: Bool = true,
                onCommit: @escaping () -> Void) {
        _message = message
        _amends = amends
        self.author = author
        self.summaryLimit = summaryLimit
        self.canCommit = canCommit
        self.onCommit = onCommit
    }

    /// The first line's length.
    static func summaryLength(_ message: String) -> Int {
        message.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(\.count) ?? 0
    }

    public var body: some View {
        let length = Self.summaryLength(message)
        let ready = canCommit && !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        VStack(alignment: .leading, spacing: metrics.spacing.s2) {
            ZStack(alignment: .topLeading) {
                if rendersOffscreen || message.isEmpty {
                    Text(message.isEmpty ? "Message (press ⌘↩ to commit)" : message)
                        .foregroundStyle(palette[message.isEmpty ? .fgTertiary : .fgPrimary])
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .allowsHitTesting(false)
                }
                if !rendersOffscreen {
                    TextEditor(text: $message)
                        .scrollContentBackground(.hidden)
                        .foregroundStyle(palette[.fgPrimary])
                }
            }
            .font(metrics.typography.callout)
            .padding(metrics.spacing.s2)
            // Full width offscreen too: a live TextEditor is greedy, the placeholder Text isn't.
            .frame(maxWidth: .infinity, minHeight: 80, alignment: .topLeading)
            .lumenChrome(.field)   // a raised text field, like every other field
            HStack(spacing: metrics.spacing.s2) {
                Toggle("Amend", isOn: $amends).toggleStyle(.lumenCheckbox).font(metrics.typography.callout)
                Spacer(minLength: metrics.spacing.s2)
                Text("\(length)/\(summaryLimit)").font(metrics.typography.caption.monospacedDigit())
                    .foregroundStyle(palette[length > summaryLimit ? .statusWarning : .fgTertiary])
                    .help("The first line’s length; aim for \(summaryLimit) or fewer")
                LumenAvatar(author)
                Button("Commit", action: onCommit)
                    .buttonStyle(.lumenPrimary)
                    .disabled(!ready)
                    .keyboardShortcut(.return, modifiers: .command)
                    .fixedSize()
            }
        }
    }
}

// MARK: Font picker

/// A font chosen as family, style and size: the chosen family shown in its own
/// face (menu items may draw in the system font), its styles, and the size with a stepper.
/// `onOptions` adds an Options… button.
public struct LumenFontPicker: View {
    @Binding private var family: String
    @Binding private var style: String
    @Binding private var size: Double
    private let families: [String]
    private let onOptions: (() -> Void)?

    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenMetrics) private var metrics
    @Environment(\.lumenRendersOffscreen) private var rendersOffscreen

    /// - Parameter families: the choices; `nil` lists the installed fixed-pitch families.
    public init(family: Binding<String>, style: Binding<String>, size: Binding<Double>, families: [String]? = nil,
                onOptions: (() -> Void)? = nil) {
        _family = family
        _style = style
        _size = size
        self.families = families ?? []
        self.onOptions = onOptions
    }

    /// The style names a family offers ("Regular", "Bold"…), or Regular when it isn't installed.
    static func styles(of family: String) -> [String] {
        let members = NSFontManager.shared.availableMembers(ofFontFamily: family) ?? []
        let names = members.compactMap { $0.count > 1 ? $0[1] as? String : nil }
        return names.isEmpty ? ["Regular"] : names
    }

    private var listed: [String] { families.isEmpty ? LumenCodeFont.monospacedFamilies : families }

    public var body: some View {
        HStack(spacing: metrics.spacing.s2) {
            menu(family, font: .custom(family, size: 13)) {
                ForEach(listed, id: \.self) { name in
                    Button { family = name; if !Self.styles(of: name).contains(style) { style = Self.styles(of: name).first ?? "Regular" } } label: {
                        Text(name).font(.custom(name, size: 13))
                    }
                }
            }
            menu(style, font: metrics.typography.body) {
                ForEach(Self.styles(of: family), id: \.self) { name in Button(name) { style = name } }
            }
            LumenNumberField(value: $size, in: Double(LumenCodeFont.sizeRange.lowerBound)...Double(LumenCodeFont.sizeRange.upperBound),
                             unit: "pt", width: 40)
            if let onOptions {
                Button("Options…", action: onOptions).buttonStyle(.lumenQuiet).fixedSize()
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Font")
    }

    @ViewBuilder
    private func menu<Items: View>(_ current: String, font: Font, @ViewBuilder items: () -> Items) -> some View {
        let label = HStack(spacing: metrics.spacing.s2) {
            Text(current).font(font).foregroundStyle(palette[.fgPrimary]).lineLimit(1).lumenNeverTruncates(current)
            Spacer(minLength: 0)
            LumenSymbol("chevron.up.chevron.down").font(.system(size: metrics.layout.disclosureGlyph, weight: .bold)).foregroundStyle(palette[.fgTertiary])
                .accessibilityHidden(true)
        }
        .padding(.horizontal, metrics.spacing.s3)
        .frame(minWidth: metrics.layout.fontPickerMinWidth, maxWidth: metrics.layout.fontPickerMaxWidth)
        .frame(height: metrics.layout.controlHeight)
        .lumenChrome(.popUp)
        LumenMenuButton { items() } label: { label }
    }
}

// MARK: Code sample and status row

/// Commands as a terminal shows them, for help text and settings:
/// each line after a prompt, in code type on an inset block. Text can be selected and copied.
public struct LumenCodeSample: View {
    private let lines: [String]
    private let prompt: String?

    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenMetrics) private var metrics
    @Environment(\.lumenCodeFont) private var codeFont

    /// - Parameter prompt: shown before each line (">", "$"), or `nil` for plain code.
    public init(_ lines: [String], prompt: String? = ">") {
        self.lines = lines
        self.prompt = prompt
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                HStack(alignment: .firstTextBaseline, spacing: metrics.spacing.s2) {
                    if let prompt { Text(prompt).foregroundStyle(palette[.fgTertiary]).accessibilityHidden(true) }
                    Text(line).foregroundStyle(palette[.fgPrimary]).textSelection(.enabled)
                        .lumenWrapsWithoutTruncating()
                }
            }
        }
        .font((codeFont ?? .standard).font())
        .padding(metrics.spacing.s4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette[.bgInset], in: .rect(cornerRadius: metrics.radius.lg, style: .continuous))
    }
}

/// A label and a value with an optional action,
/// the value in code type when it's a path.
public struct LumenStatusRow: View {
    private let label: String
    private let value: String
    private let monospaced: Bool
    private let action: LumenBarAction?

    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenMetrics) private var metrics
    @Environment(\.lumenCodeFont) private var codeFont

    public init(_ label: String, value: String, monospaced: Bool = false, action: LumenBarAction? = nil) {
        self.label = label
        self.value = value
        self.monospaced = monospaced
        self.action = action
    }

    public var body: some View {
        HStack(spacing: metrics.spacing.s2) {
            Text(label + ":").font(metrics.typography.callout).foregroundStyle(palette[.fgSecondary])
            Group {
                if monospaced {
                    LumenCodeValue(value: value, font: (codeFont ?? .standard).font(),
                                   nativeFont: (codeFont ?? .standard).nsFont(), color: palette[.fgPrimary],
                                   kind: value.hasPrefix("/") || value.hasPrefix("~/") ? .path : .expression, lineLimit: 2)
                } else {
                    Text(value).font(metrics.typography.callout).foregroundStyle(palette[.fgPrimary])
                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                }
            }
            if let action {
                Button(action.title, systemImage: action.systemImage ?? "magnifyingglass", action: action.perform)
                    .labelStyle(.iconOnly).buttonStyle(.lumenPanelIcon).help(action.title)
                    .lumenIconOnlyControl(action.title)
            }
        }
        // `.combine` with selectable text can recurse; one explicit element, its action named.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label): \(value)")
        .accessibilityAction(named: Text(action?.title ?? "")) { action?.perform() }
    }
}

// MARK: Store cards

/// What a store card's action shows.
public enum LumenItemState: Sendable, Hashable {
    /// Not installed: an "Install" capsule.
    case available
    /// Installed: quiet "INSTALLED" small caps.
    case installed
    /// Being installed: a progress ring.
    case installing(Double?)
}

/// An item in a store (an extension, a theme): its icon, name, author and a three-line description,
/// with Install or "Installed" at the top trailing corner.
public struct LumenItemCard: View {
    private let title: String
    private let author: String?
    private let summary: String?
    private let systemImage: String
    private let hue: LumenToken
    private let state: LumenItemState
    private let onInstall: () -> Void
    private let onOpen: () -> Void

    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenMetrics) private var metrics
    @State private var hovered = false
    @Environment(\.lumenMatchesRowHeight) private var matchesRowHeight

    public init(_ title: String, author: String? = nil, summary: String? = nil, systemImage: String, hue: LumenToken = .accent,
                state: LumenItemState, onInstall: @escaping () -> Void = {}, onOpen: @escaping () -> Void = {}) {
        self.title = title
        self.author = author
        self.summary = summary
        self.systemImage = systemImage
        self.hue = hue
        self.state = state
        self.onInstall = onInstall
        self.onOpen = onOpen
    }

    public var body: some View {
        HStack(alignment: .top, spacing: metrics.spacing.s3) {
            LumenIconTile(systemImage, hue: hue, size: metrics.layout.tilePaneHeader)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title).font(metrics.typography.headline).foregroundStyle(palette[.fgPrimary]).lineLimit(1)
                            .lumenNeverTruncates(title)
                        if let author { Text(author).font(metrics.typography.caption).foregroundStyle(palette[.fgTertiary]).lineLimit(1).truncationMode(.tail).help(author) }
                    }
                    Spacer(minLength: metrics.spacing.s2)
                    action
                }
                if let summary {
                    Text(summary).font(metrics.typography.caption).foregroundStyle(palette[.fgSecondary])
                        .lineLimit(3).fixedSize(horizontal: false, vertical: true).help(summary).padding(.top, metrics.spacing.s1)
                }
            }
        }
        .padding(metrics.spacing.s4)
        .lumenFixedContainer("Item card")
        // A fixed width, the height of its content: no dead band under a short description. In a
        // carousel row it grows to the tallest card's height, so the row's bottom edges line up.
        .frame(width: 300, alignment: .topLeading)
        .frame(maxHeight: matchesRowHeight ? .infinity : nil, alignment: .top)
        .background(palette[hovered ? .bgHover : .bgElevated], in: .rect(cornerRadius: metrics.radius.lg, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: metrics.radius.lg, style: .continuous).strokeBorder(palette[.borderSubtle], lineWidth: metrics.stroke.hairline) }
        .contentShape(.rect)
        .onTapGesture(perform: onOpen)
        .onHover { hovered = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel([title, author, summary].compactMap(\.self).joined(separator: ", "))
    }

    @ViewBuilder private var action: some View {
        switch state {
        case .available:
            // One Install button (the managed tool row's too): the tinted panel-action style, 24 pt, 13 pt.
            Button("Install", action: onInstall)
                .buttonStyle(LumenTintedButtonStyle())
                .fixedSize()
        case .installed:
            // A status, so sentence case (capitals are for group labels and table headers only).
            Text("Installed").font(metrics.typography.caption.weight(.semibold)).foregroundStyle(palette[.fgTertiary]).fixedSize()
        case .installing(let progress):
            LumenProgressRing(progress: progress).frame(width: 16, height: 16)
        }
    }
}

/// The carousel's scroll coordinate space. A global constant: a generic view's `Self.space` would
/// capture its metatype in the Sendable geometry closure (Swift 6).
private let lumenCarouselSpace = "LumenCarousel"

/// A titled row of cards that scrolls sideways, with round ← → buttons at its ends. Each arrow steps one card and hides at its end; the clipped edges
/// fade out (a mask, so the fade is right on any ground).
public struct LumenCarousel<ID: Hashable, Card: View>: View {
    private let title: String
    private let ids: [ID]
    private let card: (ID) -> Card

    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenMetrics) private var metrics
    @Environment(\.lumenRendersOffscreen) private var rendersOffscreen
    @State private var position: ID?
    @State private var viewport: CGFloat = 0
    @State private var atStart = true
    @State private var atEnd = false

    /// The width of an edge's fade.
    static var fadeWidth: CGFloat { 56 }

    /// - Parameters:
    ///   - ids: the cards, in order; the arrows step through them.
    ///   - card: the card for an id.
    public init(_ title: String, ids: [ID], @ViewBuilder card: @escaping (ID) -> Card) {
        self.title = title
        self.ids = ids
        self.card = card
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: metrics.spacing.s3) {
            Text(title).font(metrics.typography.title3).foregroundStyle(palette[.fgPrimary]).accessibilityAddTraits(.isHeader)
            if rendersOffscreen {
                // Every card fits: no fade, no arrow (as live, where both ends are in view). Otherwise
                // the first card leads, so only the trailing edge is clipped: its fade and its arrow.
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: metrics.spacing.s3) { ForEach(ids, id: \.self) { card($0) } }
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(alignment: .top, spacing: metrics.spacing.s3) { ForEach(ids, id: \.self) { card($0) } }
                        .fixedSize()
                        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                        .clipped()
                        .mask { fadeMask(leading: false, trailing: true) }
                        .overlay(alignment: .trailing) { if ids.count > 1 { arrow("chevron.right", "Next") {} } }
                }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: metrics.spacing.s3) {
                        ForEach(ids, id: \.self) { id in
                            card(id)
                                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(lumenCarouselSpace)) } action: { frame in
                                    if id == ids.first { atStart = frame.minX >= -1 }
                                    if id == ids.last { atEnd = frame.maxX <= viewport + 1 }
                                }
                                .onDisappear {
                                    if id == ids.first { atStart = false }
                                    if id == ids.last { atEnd = false }
                                }
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)   // the row is its tallest card's height
                    .scrollTargetLayout()
                }
                .coordinateSpace(.named(lumenCarouselSpace))
                .scrollTargetBehavior(.viewAligned)
                .scrollPosition(id: $position)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { viewport = $0 }
                .mask { fadeMask(leading: !atStart, trailing: !atEnd) }
                .overlay(alignment: .leading) { if !atStart { arrow("chevron.left", "Previous") { step(-1) } } }
                .overlay(alignment: .trailing) { if !atEnd, ids.count > 1 { arrow("chevron.right", "Next") { step(1) } } }
            }
        }
        // Item cards in the row stretch to the tallest one (the stacks size themselves to fit).
        .environment(\.lumenMatchesRowHeight, true)
    }


    /// Moves the leading card one id along `direction`, stopping at the ends.
    private func step(_ direction: Int) {
        guard !ids.isEmpty else { return }
        let current = position.flatMap { ids.firstIndex(of: $0) } ?? 0
        let next = min(max(current + direction, 0), ids.count - 1)
        withAnimation(.snappy) { position = ids[next] }
    }

    /// Opaque in the middle, fading out at a clipped edge, so cards dim under the arrows on any ground.
    private func fadeMask(leading: Bool, trailing: Bool) -> some View {
        HStack(spacing: 0) {
            if leading { LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing).frame(width: Self.fadeWidth) }
            Rectangle()
            if trailing { LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: Self.fadeWidth) }
        }
    }

    private func arrow(_ symbol: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(title, systemImage: symbol, action: action)
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .font(.system(size: metrics.layout.paneActionGlyph, weight: .bold))
            .foregroundStyle(palette[.fgSecondary])
            .frame(width: 30, height: 30)
            .background(palette[.bgElevated], in: .circle)
            .overlay { Circle().strokeBorder(palette[.borderDefault], lineWidth: metrics.stroke.hairline) }
            .contentShape(.circle)
            .lumenIconOnlyControl(title)
            .help(title)
    }
}

public extension LumenCarousel where ID == Int {
    /// Cards given as one view: it scrolls, but has no ids for the arrows to step through, so it shows
    /// none. Prefer `init(_:ids:card:)`.
    init(_ title: String, @ViewBuilder content: () -> Card) {
        let content = content()
        self.init(title, ids: [0]) { _ in content }
    }
}

// MARK: Detail header

/// The top of an item's page in a store: its icon and name, its categories,
/// meta on the trailing side ("Version 1.3.6 · 3 years ago"), the primary action and
/// Share, a row of icon links, and what it's allowed to do.
public struct LumenDetailHeader: View {
    private let title: String
    private let summary: String?
    private let systemImage: String
    private let hue: LumenToken
    private let categories: [String]
    private let meta: [String]
    private let links: [LumenBarAction]
    private let permissions: [(String, String)]
    private let primary: LumenBarAction?
    private let onShare: (() -> Void)?

    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenMetrics) private var metrics

    /// - Parameter permissions: what it may do, each a title and a glyph ("Read & Write Files", "pencil").
    public init(_ title: String, summary: String? = nil, systemImage: String, hue: LumenToken = .accent, categories: [String] = [],
                meta: [String] = [], links: [LumenBarAction] = [], permissions: [(String, String)] = [],
                primary: LumenBarAction? = nil, onShare: (() -> Void)? = nil) {
        self.title = title
        self.summary = summary
        self.systemImage = systemImage
        self.hue = hue
        self.categories = categories
        self.meta = meta
        self.links = links
        self.permissions = permissions
        self.primary = primary
        self.onShare = onShare
    }

    public var body: some View {
        HStack(alignment: .top, spacing: metrics.spacing.s4) {
            LumenIconTile(systemImage, hue: hue, size: metrics.layout.tileHeroCompact)
            VStack(alignment: .leading, spacing: metrics.spacing.s2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title).font(metrics.typography.title2).foregroundStyle(palette[.fgPrimary]).accessibilityAddTraits(.isHeader)
                    Spacer(minLength: metrics.spacing.s3)
                    if let primary {
                        // The page's primary action reads as one (a quiet label looked disabled).
                        Button(primary.title, action: primary.perform).buttonStyle(.lumenPrimary).disabled(!primary.isEnabled).fixedSize()
                    }
                    if let onShare {
                        Button("Share", systemImage: "square.and.arrow.up", action: onShare)
                            .labelStyle(.iconOnly).buttonStyle(.lumenPanelIcon).help("Share")
                            .lumenIconOnlyControl("Share")
                    }
                }
                HStack(spacing: metrics.spacing.s3) {
                    // Categories are labels, not links: no underline.
                    ForEach(categories, id: \.self) { Text($0).font(metrics.typography.callout).foregroundStyle(palette[.fgSecondary]) }
                    Spacer(minLength: metrics.spacing.s3)
                    Text(meta.joined(separator: " · ")).font(metrics.typography.caption).foregroundStyle(palette[.fgTertiary]).lineLimit(1).truncationMode(.tail).help(meta.joined(separator: " · "))
                }
                if let summary {
                    Text(summary).font(metrics.typography.body).foregroundStyle(palette[.fgSecondary]).lumenWrapsWithoutTruncating()
                }
                if !links.isEmpty {
                    HStack(spacing: metrics.spacing.s5) {
                        ForEach(links) { link in
                            Button(action: link.perform) {
                                HStack(spacing: metrics.spacing.s1) {
                                    if let symbol = link.systemImage { LumenSymbol(symbol) }
                                    Text(link.title)
                                }
                                .font(metrics.typography.callout)
                                .foregroundStyle(palette[.fgLink])
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.top, metrics.spacing.s1)
                }
                if !permissions.isEmpty {
                    HStack(spacing: metrics.spacing.s4) {
                        Text("Allowed to:").font(metrics.typography.caption).foregroundStyle(palette[.fgTertiary])
                        ForEach(permissions, id: \.0) { permission in
                            HStack(spacing: metrics.spacing.s1) {
                                LumenSymbol(permission.1)
                                Text(permission.0)
                            }
                            .font(metrics.typography.caption)
                            .foregroundStyle(palette[.fgSecondary])
                        }
                    }
                }
            }
        }
        // No top inset: its top lines up with neighbours in a top-aligned row; the page gives the margin above.
        .padding([.horizontal, .bottom], metrics.spacing.s5)
    }
}

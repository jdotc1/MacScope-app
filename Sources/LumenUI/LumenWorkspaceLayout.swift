import AppKit
import SwiftUI
import LumenTokens

// Split editor panes and stacked sidebar panes: the focused pane carries the
// accent and the others dim; sidebar panes stack under tiled headers with counts.

// MARK: Layout model

/// One editor pane: its tabs and which is showing.
public struct LumenEditorPane: Identifiable, Hashable {
    public let id: String
    public var tabs: [LumenDocumentTab]
    public var selection: String?

    public init(id: String = UUID().uuidString, tabs: [LumenDocumentTab], selection: String? = nil) {
        self.id = id
        self.tabs = tabs
        self.selection = selection ?? tabs.first?.id
    }

    /// Pinned tabs first, each group in its own order.
    public var orderedTabs: [LumenDocumentTab] { tabs.filter(\.isPinned) + tabs.filter { !$0.isPinned } }
}

/// Editor panes side by side, and which has focus. Every edit a `LumenSplitEditor` makes goes
/// through here, so an app can save it, restore it, or make the same edits from its menus.
public struct LumenEditorLayout: Hashable {
    public var panes: [LumenEditorPane]
    public var focusedPaneID: String?

    public init(panes: [LumenEditorPane], focusedPaneID: String? = nil) {
        self.panes = panes
        self.focusedPaneID = focusedPaneID ?? panes.first?.id
    }

    /// The focused pane, or the first.
    public var focusedPane: LumenEditorPane? { panes.first { $0.id == focusedPaneID } ?? panes.first }

    private func index(of paneID: String) -> Int? { panes.firstIndex { $0.id == paneID } }

    /// Opens a tab in the focused pane: selects it if it's open there; otherwise replaces that pane's
    /// preview tab when the new one is a preview, or adds it.
    public mutating func open(_ tab: LumenDocumentTab) {
        guard let paneID = focusedPane?.id, let p = index(of: paneID) else {
            panes = [LumenEditorPane(tabs: [tab])]
            focusedPaneID = panes[0].id
            return
        }
        if !panes[p].tabs.contains(where: { $0.id == tab.id }) {
            if tab.isPreview, let preview = panes[p].tabs.firstIndex(where: \.isPreview) {
                panes[p].tabs[preview] = tab
            } else {
                panes[p].tabs.append(tab)
            }
        }
        panes[p].selection = tab.id
    }

    public mutating func select(_ tabID: String?, inPane paneID: String) {
        guard let p = index(of: paneID) else { return }
        panes[p].selection = tabID
        focusedPaneID = paneID
    }

    /// Closes a tab; its neighbor shows. A pane left empty closes, unless it's the last.
    public mutating func close(_ tabID: String, inPane paneID: String) {
        guard let p = index(of: paneID), let t = panes[p].orderedTabs.firstIndex(where: { $0.id == tabID }) else { return }
        let ordered = panes[p].orderedTabs
        panes[p].tabs.removeAll { $0.id == tabID }
        if panes[p].selection == tabID {
            let remaining = ordered.filter { $0.id != tabID }
            panes[p].selection = remaining.isEmpty ? nil : remaining[min(t, remaining.count - 1)].id
        }
        if panes[p].tabs.isEmpty, panes.count > 1 { closePane(paneID) }
    }

    /// Closes every unpinned tab but this one. `shouldClose` is asked once for each of them (an
    /// unsaved document, say); a tab it refuses stays open.
    public mutating func closeOthers(_ tabID: String, inPane paneID: String, shouldClose: (LumenDocumentTab) -> Bool = { _ in true }) {
        guard let p = index(of: paneID) else { return }
        panes[p].tabs.removeAll { $0.id != tabID && !$0.isPinned && shouldClose($0) }
        panes[p].selection = tabID
    }

    /// Closes every unpinned tab in the pane, each that `shouldClose` allows.
    public mutating func closeAll(inPane paneID: String, shouldClose: (LumenDocumentTab) -> Bool = { _ in true }) {
        guard let p = index(of: paneID) else { return }
        panes[p].tabs.removeAll { !$0.isPinned && shouldClose($0) }
        if !panes[p].tabs.contains(where: { $0.id == panes[p].selection }) { panes[p].selection = panes[p].orderedTabs.first?.id }
        if panes[p].tabs.isEmpty, panes.count > 1 { closePane(paneID) }
    }

    public mutating func togglePin(_ tabID: String, inPane paneID: String) {
        guard let p = index(of: paneID), let t = panes[p].tabs.firstIndex(where: { $0.id == tabID }) else { return }
        panes[p].tabs[t].isPinned.toggle()
    }

    /// Moves a tab, from whichever pane holds it, to a pane before the tab at `position` in that
    /// pane's order (the end when past it). A pane left empty closes.
    public mutating func move(_ tabID: String, toPane paneID: String, at position: Int) {
        move(tabID, fromPane: nil, toPane: paneID, at: position)
    }

    /// Moves a tab from `sourcePaneID` (the first pane holding it when `nil`, or when that pane no
    /// longer holds it). Name the source when the same tab is open in two panes (after Duplicate in
    /// Split), or the move takes it from the wrong one. A tab already open in the destination moves
    /// there rather than opening twice. A pane left empty closes.
    public mutating func move(_ tabID: String, fromPane sourcePaneID: String?, toPane paneID: String, at position: Int) {
        let named = sourcePaneID.flatMap { id in panes.firstIndex { $0.id == id && $0.tabs.contains { $0.id == tabID } } }
        guard let from = named ?? panes.firstIndex(where: { $0.tabs.contains { $0.id == tabID } }), let to = index(of: paneID),
              let tab = panes[from].tabs.first(where: { $0.id == tabID }) else { return }
        let fromID = panes[from].id
        let target = panes[to].orderedTabs
        let before = position < target.count ? target[position].id : nil
        guard before != tabID || from != to else { return }
        panes[from].tabs.removeAll { $0.id == tabID }
        if panes[from].selection == tabID { panes[from].selection = panes[from].orderedTabs.first?.id }
        // The destination's own copy gives way to the moved one, so its tab ids stay distinct
        // (dropped on that copy, the copy stays where it is).
        if before != tabID { panes[to].tabs.removeAll { $0.id == tabID } }
        guard let toNow = index(of: paneID) else { return }
        if before != tabID {
            if let before, let i = panes[toNow].tabs.firstIndex(where: { $0.id == before }) {
                panes[toNow].tabs.insert(tab, at: i)
            } else {
                panes[toNow].tabs.append(tab)
            }
        }
        panes[toNow].selection = tabID
        focusedPaneID = paneID
        if fromID != paneID, let f = index(of: fromID), panes[f].tabs.isEmpty, panes.count > 1 { closePane(fromID) }
    }

    /// Opens a copy of a tab in a new pane beside its own, and focuses it. Returns the new pane's id.
    @discardableResult
    public mutating func split(_ tabID: String, fromPane paneID: String, edge: LumenSplitEdge) -> String? {
        guard let p = index(of: paneID), let tab = panes[p].tabs.first(where: { $0.id == tabID }) else { return nil }
        var copy = tab
        copy.isPinned = false
        let pane = LumenEditorPane(tabs: [copy])
        panes.insert(pane, at: edge == .leading ? p : p + 1)
        focusedPaneID = pane.id
        return pane.id
    }

    /// Closes a pane (not the last). `shouldClose` is asked once for each of its tabs; if it refuses
    /// any, the pane stays open with those tabs and the rest close.
    public mutating func closePane(_ paneID: String, shouldClose: (LumenDocumentTab) -> Bool) {
        guard panes.count > 1, let p = index(of: paneID) else { return }
        let kept = panes[p].tabs.filter { !shouldClose($0) }
        guard !kept.isEmpty else { return closePane(paneID) }
        panes[p].tabs = kept
        if !kept.contains(where: { $0.id == panes[p].selection }) { panes[p].selection = panes[p].orderedTabs.first?.id }
    }

    public mutating func closePane(_ paneID: String) {
        guard panes.count > 1, let p = index(of: paneID) else { return }
        panes.remove(at: p)
        if focusedPaneID == paneID { focusedPaneID = panes[min(p, panes.count - 1)].id }
    }
}

// MARK: Split editor

/// Editor panes side by side: each with its own tab bar, close and maximize at the
/// leading edge and New Split at the trailing edge. The focused pane's active tab carries the accent;
/// the other panes' tabs go quiet and their content dims. Dividers drag; panes never
/// narrow past `minimumPaneWidth`. Tabs have the full menu (pin, close others, duplicate in a split)
/// and drag between panes.
public struct LumenSplitEditor<Content: View>: View {
    @Binding private var layout: LumenEditorLayout
    private let minimumPaneWidth: CGFloat
    private let onCloseTab: ((LumenDocumentTab, String) -> Bool)?
    private let content: (LumenEditorPane) -> Content

    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenMetrics) private var metrics
    @State private var weights: [String: CGFloat] = [:]
    @State private var dragStart: [String: CGFloat]?
    @State private var maximizedPaneID: String?

    /// - Parameters:
    ///   - onCloseTab: asked before a tab closes (an unsaved document, say); return `false` to keep it.
    ///   - content: the editor for a pane, showing its selected tab.
    public init(layout: Binding<LumenEditorLayout>, minimumPaneWidth: CGFloat = 220,
                onCloseTab: ((LumenDocumentTab, String) -> Bool)? = nil,
                @ViewBuilder content: @escaping (LumenEditorPane) -> Content) {
        _layout = layout
        self.minimumPaneWidth = minimumPaneWidth
        self.onCloseTab = onCloseTab
        self.content = content
    }

    private var visiblePanes: [LumenEditorPane] {
        if let maximizedPaneID, let pane = layout.panes.first(where: { $0.id == maximizedPaneID }) { return [pane] }
        return layout.panes
    }

    public var body: some View {
        GeometryReader { proxy in
            let panes = visiblePanes
            let widths = Self.widths(for: panes.map { weights[$0.id] ?? 1 }, total: proxy.size.width - CGFloat(max(panes.count - 1, 0)),
                                     minimum: minimumPaneWidth)
            HStack(spacing: 0) {
                ForEach(Array(panes.enumerated()), id: \.element.id) { index, pane in
                    paneView(pane).lumenColumnWidthWatch("Editor pane", isActive: true).frame(width: widths[index])
                    if index < panes.count - 1 { divider(between: pane.id, and: panes[index + 1].id, total: proxy.size.width) }
                }
            }
        }
        // Every visible pane keeps `minimumPaneWidth`: the editor's minimum covers them all and the
        // dividers between them (it used to cover one, so three splits squeezed each pane below it).
        .frame(minWidth: minimumPaneWidth * CGFloat(max(visiblePanes.count, 1)) + metrics.stroke.hairline * CGFloat(max(visiblePanes.count - 1, 0)))
        .onChange(of: layout.panes.map(\.id)) { _, ids in
            if let maximizedPaneID, !ids.contains(maximizedPaneID) { self.maximizedPaneID = nil }
        }
    }

    /// Each pane's width from its weight, at least `minimum` when there's room for all.
    static func widths(for weights: [CGFloat], total: CGFloat, minimum: CGFloat) -> [CGFloat] {
        guard !weights.isEmpty else { return [] }
        let sum = weights.reduce(0, +)
        var widths = weights.map { max(total * $0 / max(sum, 0.0001), 0) }
        if total >= minimum * CGFloat(weights.count) {
            // Lift narrow panes to the minimum, taking the difference from the wider ones in proportion.
            for _ in 0..<weights.count {
                let short = widths.indices.filter { widths[$0] < minimum }
                guard !short.isEmpty else { break }
                let deficit = short.reduce(0) { $0 + minimum - widths[$1] }
                short.forEach { widths[$0] = minimum }
                let donors = widths.indices.filter { widths[$0] > minimum }
                let spare = donors.reduce(0) { $0 + widths[$1] - minimum }
                guard spare > 0 else { break }
                donors.forEach { widths[$0] -= deficit * (widths[$0] - minimum) / spare }
            }
        }
        return widths
    }

    private func isFocused(_ pane: LumenEditorPane) -> Bool { layout.focusedPane?.id == pane.id }

    private func paneView(_ pane: LumenEditorPane) -> some View {
        let focused = isFocused(pane)
        let several = layout.panes.count > 1
        return VStack(spacing: 0) {
            HStack(spacing: 0) {
                if several {
                    paneButton("Close Split", symbol: "xmark") { layout.closePane(pane.id, shouldClose: mayClose(inPane: pane.id)) }
                    paneButton(maximizedPaneID == pane.id ? "Restore Splits" : "Magnify Split",
                               symbol: maximizedPaneID == pane.id ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right") {
                        maximizedPaneID = maximizedPaneID == pane.id ? nil : pane.id
                    }
                }
                LumenDocumentTabBar(pane.orderedTabs,
                                    selection: Binding(get: { pane.selection }, set: { layout.select($0, inPane: pane.id) }),
                                    onClose: { tab in
                                        if mayClose(inPane: pane.id)(tab) { layout.close(tab.id, inPane: pane.id) }
                                    },
                                    actions: tabActions(for: pane))
                paneButton("New Split", symbol: "rectangle.split.2x1") {
                    maximizedPaneID = nil
                    if let tab = pane.selection { layout.split(tab, fromPane: pane.id, edge: .trailing) }
                }
                .disabled(pane.selection == nil)
            }
            .frame(height: metrics.layout.tabHeight)
            .background(palette[.bgWindow])
            .overlay(alignment: .bottom) { Rectangle().fill(palette[.borderSubtle]).frame(height: metrics.stroke.hairline) }
            // Tabs dragged from this pane say so, since a duplicated tab is open in two panes.
            .environment(\.lumenTabDragPane, pane.id)
            content(pane)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay {
                    if several && !focused && maximizedPaneID == nil {
                        palette[.bgCanvas].opacity(0.4).allowsHitTesting(false).accessibilityHidden(true)
                    }
                }
        }
        .environment(\.lumenPaneIsFocused, focused || !several)
        .simultaneousGesture(TapGesture().onEnded { layout.focusedPaneID = pane.id })
        .accessibilityElement(children: .contain)
        .accessibilityLabel(focused ? "Focused editor pane" : "Editor pane")
    }

    /// Every way a tab closes asks `onCloseTab` first: the close button, Close Others, Close All and
    /// Close Split alike.
    private func mayClose(inPane paneID: String) -> (LumenDocumentTab) -> Bool {
        { tab in onCloseTab?(tab, paneID) ?? true }
    }

    private func tabActions(for pane: LumenEditorPane) -> LumenTabActions {
        var actions = LumenTabActions(
            closeOthers: { layout.closeOthers($0.id, inPane: pane.id, shouldClose: mayClose(inPane: pane.id)) },
            closeAll: { layout.closeAll(inPane: pane.id, shouldClose: mayClose(inPane: pane.id)) },
            togglePin: { layout.togglePin($0.id, inPane: pane.id) },
            duplicateInSplit: { tab, edge in
                maximizedPaneID = nil
                layout.split(tab.id, fromPane: pane.id, edge: edge)
            },
            dropTab: { id, position in layout.move(id, toPane: pane.id, at: position) })
        actions.moveTab = { id, source, position in layout.move(id, fromPane: source, toPane: pane.id, at: position) }
        return actions
    }

    private func paneButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        // A pane's own button: the content's ink, not the toolbar's.
        Button(title, systemImage: symbol, action: action)
            .labelStyle(.iconOnly)
            .buttonStyle(.lumenPanelIcon)
            .lumenIconOnlyControl(title)
            .font(.system(size: metrics.iconSize.xsmall, weight: .semibold))
            .help(title)
            .padding(.horizontal, 2)
    }

    private func divider(between leading: String, and trailing: String, total: CGFloat) -> some View {
        Rectangle()
            .fill(palette[.borderDefault])
            .frame(width: metrics.stroke.hairline)
            .overlay {
                Color.clear.frame(width: 8).contentShape(.rect)
                    .modifier(LumenResizeCursor(cursor: .resizeLeftRight, isDragging: dragStart != nil))
                    .gesture(DragGesture(minimumDistance: 1)
                        .onChanged { value in
                            let start = dragStart ?? Dictionary(uniqueKeysWithValues: layout.panes.map { ($0.id, weights[$0.id] ?? 1) })
                            if dragStart == nil { dragStart = start }
                            let sum = visiblePanes.reduce(0) { $0 + (start[$1.id] ?? 1) }
                            let delta = value.translation.width / max(total, 1) * sum
                            let a = (start[leading] ?? 1) + delta, b = (start[trailing] ?? 1) - delta
                            let floor = sum * minimumPaneWidth / max(total, 1)
                            guard a >= floor, b >= floor else { return }
                            weights[leading] = a
                            weights[trailing] = b
                        }
                        .onEnded { _ in dragStart = nil })
            }
            .accessibilityHidden(true)
    }
}

// MARK: Stacked sidebar

/// One pane in a stacked sidebar.
public struct LumenStackedPane: Identifiable {
    public let id: String
    public let title: String
    public let systemImage: String
    public let hue: LumenToken
    public let count: Int?
    /// Shown instead of the content while `count` is 0.
    public let emptyMessage: String?
    /// Buttons at the header's trailing edge, as glyphs with their titles as help.
    public let actions: [LumenBarAction]
    public let content: AnyView

    public init<Content: View>(id: String, title: String, systemImage: String, hue: LumenToken = .accent, count: Int? = nil,
                               emptyMessage: String? = nil, actions: [LumenBarAction] = [], @ViewBuilder content: () -> Content) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.hue = hue
        self.count = count
        self.emptyMessage = emptyMessage
        self.actions = actions
        self.content = AnyView(content())
    }
}

/// Several panes in one sidebar, each under a tiled header
/// with its count: click a header to collapse its pane; drag the grip between open
/// panes to share the height. Content scrolls only when its pane is too short.
public struct LumenStackedSidebar: View {
    private let panes: [LumenStackedPane]
    @Binding private var collapsed: Set<String>

    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenMetrics) private var metrics
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var weights: [String: CGFloat] = [:]
    @State private var dragStart: [String: CGFloat]?

    /// The 28 pt section tile with 4 pt above and below: `layout.paneHeaderHeight`, every header that
    /// carries a section tile.
    static var headerHeight: CGFloat { LumenMetrics.standard.layout.paneHeaderHeight }
    static let gripHeight: CGFloat = 7
    static let minimumPaneHeight: CGFloat = 60

    /// The headers and grips, drawn whatever is collapsed: the sidebar's minimum height.
    static func chromeHeight(paneCount: Int, headerHeight: CGFloat) -> CGFloat {
        CGFloat(paneCount) * headerHeight + CGFloat(max(paneCount - 1, 0)) * gripHeight
    }

    /// - Parameter collapsed: the ids of collapsed panes (keep it in `@SceneStorage` to remember).
    public init(_ panes: [LumenStackedPane], collapsed: Binding<Set<String>>) {
        self.panes = panes
        _collapsed = collapsed
    }

    public var body: some View {
        GeometryReader { proxy in
            let open = panes.filter { !collapsed.contains($0.id) }
            let chrome = Self.chromeHeight(paneCount: panes.count, headerHeight: metrics.layout.paneHeaderHeight)
            let room = max(proxy.size.height - chrome, 0)
            let sum = open.reduce(0) { $0 + (weights[$1.id] ?? 1) }
            VStack(spacing: 0) {
                ForEach(Array(panes.enumerated()), id: \.element.id) { index, pane in
                    header(pane)
                    if !collapsed.contains(pane.id) {
                        body(of: pane).frame(height: room * (weights[pane.id] ?? 1) / max(sum, 0.0001))
                    }
                    if index < panes.count - 1 { grip(after: index, room: room) }
                }
                Spacer(minLength: 0)
            }
        }
        // The headers and the grips between them are always drawn, so the minimum covers both.
        .frame(minHeight: Self.chromeHeight(paneCount: panes.count, headerHeight: metrics.layout.paneHeaderHeight))
        .animation(metrics.motion.animation(metrics.motion.standardCurve, reduceMotion: reduceMotion), value: collapsed)
    }

    private func header(_ pane: LumenStackedPane) -> some View {
        let isOpen = !collapsed.contains(pane.id)
        let toggle = { if isOpen { collapsed.insert(pane.id) } else { collapsed.remove(pane.id) } }
        return HStack(spacing: metrics.spacing.s2) {
            Button(action: toggle) {
                HStack(spacing: metrics.spacing.s2) {
                    LumenIconTile(pane.systemImage, hue: pane.hue, size: metrics.layout.tileSection)
                        .lumenIconRole(.section)
                    Text(pane.title).font(metrics.typography.headline).foregroundStyle(palette[.sidebarForeground]).lineLimit(1)
                        .lumenNeverTruncates(pane.title)
                    if let count = pane.count { LumenCount(count) }
                    Spacer(minLength: 0)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.lumenBare)
            .accessibilityLabel(pane.title + (pane.count.map { ", \($0)" } ?? ""))
            .accessibilityValue(isOpen ? "Expanded" : "Collapsed")
            ForEach(pane.actions) { action in
                Button(action: action.perform) { LumenSymbol(action.systemImage ?? "circle").font(.system(size: metrics.layout.paneActionGlyph)) }
                    .buttonStyle(.lumenPanelIcon)
                    .lumenIconOnlyControl(action.title)
                    .disabled(!action.isEnabled)
                    .help(action.title)
                    .accessibilityLabel(action.title)
            }
            // The collapse state as a shape, not only to VoiceOver: it turns down while open.
            // In a fixed trailing slot after any actions, so every pane's chevron sits in one column.
            Button(action: toggle) {
                LumenSymbol("chevron.right")
                    .font(.system(size: metrics.iconSize.xsmall, weight: .semibold))
                    .foregroundStyle(palette[.sidebarSecondaryForeground])
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
                    .frame(width: metrics.layout.minimumHitTarget, height: metrics.layout.paneHeaderHeight)
                    .contentShape(.rect)
            }
            .buttonStyle(.lumenBare)
            .lumenIconOnlyControl(isOpen ? "Collapse \(pane.title)" : "Expand \(pane.title)")
            .help(isOpen ? "Collapse \(pane.title)" : "Expand \(pane.title)")
            // The header button already speaks the state; this is its pointer-sized twin.
            .accessibilityHidden(true)
        }
        .padding(.horizontal, metrics.spacing.s3)
        .frame(height: metrics.layout.paneHeaderHeight)
    }

    @ViewBuilder private func body(of pane: LumenStackedPane) -> some View {
        Group {
            if pane.count == 0, let empty = pane.emptyMessage {
                LumenEmptyState.inline(empty)
                    .padding(.horizontal, metrics.spacing.s3).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ViewThatFits(in: .vertical) {
                    pane.content.lumenColumnWidthWatch(pane.title, isActive: true)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    ScrollView { pane.content.lumenColumnWidthWatch(pane.title, isActive: true).frame(maxWidth: .infinity, alignment: .topLeading) }
                }
            }
        }
        .clipped()
    }

    /// The grip under pane `index`: it drags when the panes on both sides are open.
    private func grip(after index: Int, room: CGFloat) -> some View {
        let above = panes[...index].last { !collapsed.contains($0.id) }
        let below = panes[(index + 1)...].first { !collapsed.contains($0.id) }
        let active = above != nil && below != nil && !collapsed.contains(panes[index].id)
        return ZStack {
            Rectangle().fill(palette[.borderSubtle]).frame(height: metrics.stroke.hairline)
            if active { Capsule().fill(palette[.fgTertiary].opacity(0.5)).frame(width: 18, height: 3) }
        }
        .frame(height: Self.gripHeight)
        .contentShape(.rect)
        .modifier(LumenResizeCursor(cursor: .resizeUpDown, isActive: active, isDragging: dragStart != nil))
        .gesture(DragGesture(minimumDistance: 1)
            .onChanged { value in
                guard active, let above, let below else { return }
                let open = panes.filter { !collapsed.contains($0.id) }
                let start = dragStart ?? Dictionary(uniqueKeysWithValues: open.map { ($0.id, weights[$0.id] ?? 1) })
                if dragStart == nil { dragStart = start }
                let sum = open.reduce(0) { $0 + (start[$1.id] ?? 1) }
                let delta = value.translation.height / max(room, 1) * sum
                let a = (start[above.id] ?? 1) + delta, b = (start[below.id] ?? 1) - delta
                let floor = sum * Self.minimumPaneHeight / max(room, 1)
                guard a >= floor, b >= floor else { return }
                weights[above.id] = a
                weights[below.id] = b
            }
            .onEnded { _ in dragStart = nil })
        .accessibilityHidden(true)
    }
}

/// The resize cursor over a split's grip, pushed and popped in balance: it stays while a drag runs
/// past the grip, and pops when the grip goes away mid-hover (a pane closed) or stops being active
/// (a pane collapsed between enter and exit), as `LumenBottomPanelContainer`'s does.
struct LumenResizeCursor: ViewModifier {
    let cursor: NSCursor
    var isActive = true
    let isDragging: Bool
    @State private var isHovering = false
    @State private var pushed = false

    func body(content: Content) -> some View {
        content
            .onHover { isHovering = $0; update() }
            .onChange(of: isDragging) { update() }
            .onChange(of: isActive) { update() }
            .onDisappear { isHovering = false; if pushed { NSCursor.pop(); pushed = false } }
    }

    private func update() {
        let wanted = isActive && (isHovering || isDragging)
        if wanted, !pushed { cursor.push(); pushed = true }
        if !wanted, pushed { NSCursor.pop(); pushed = false }
    }
}

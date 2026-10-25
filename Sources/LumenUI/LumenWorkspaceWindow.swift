import SwiftUI
import LumenTokens

// The workspace window as one component, so the rules that keep it intact live in
// Lumen rather than in each app: the top bar is pinned at the top (in the title bar band, the
// unified row; or under the window buttons' band) and can never be pushed off screen, every region is always mounted and collapses to zero rather than leaving the
// split view, no region can ask for more height than the window has, and the panel toggles and
// their commands come with it. `LumenConformance.workspaceWindow` checks an app's window keeps
// these rules at every size and panel combination.

/// Which of a workspace window's panels show.
public struct LumenWorkspacePanels: Hashable, Sendable {
    public var leading: Bool
    public var bottom: Bool
    public var trailing: Bool

    public init(leading: Bool = true, bottom: Bool = false, trailing: Bool = true) {
        self.leading = leading
        self.bottom = bottom
        self.trailing = trailing
    }

    /// Every combination of shown and hidden panels, for conformance checks.
    public static let allCombinations: [LumenWorkspacePanels] = [false, true].flatMap { leading in
        [false, true].flatMap { bottom in [false, true].map { LumenWorkspacePanels(leading: leading, bottom: bottom, trailing: $0) } }
    }
}

/// The top bar's frame in the window (global coordinates), reported for `LumenConformance.workspaceWindow`.
public struct LumenTopBarFrameKey: PreferenceKey {
    public static let defaultValue: CGRect? = nil
    public static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) { value = nextValue() ?? value }
}

/// The highest top edge of any workspace region (global coordinates), reported for
/// `LumenConformance.workspaceWindow`: no region may start above the top bar's bottom edge.
public struct LumenRegionTopKey: PreferenceKey {
    public static let defaultValue: CGFloat? = nil
    public static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
        if let next = nextValue() { value = min(value ?? next, next) }
    }
}

private struct LumenRegionTopReporter: ViewModifier {
    func body(content: Content) -> some View {
        content.background {
            GeometryReader { proxy in
                Color.clear.preference(key: LumenRegionTopKey.self, value: proxy.size.height > 0.5 && proxy.size.width > 0.5 ? proxy.frame(in: .global).minY : nil)
            }
        }
    }
}

private struct LumenPinnedTopBar<Bar: View>: ViewModifier {
    let bar: Bar
    /// `nil` takes the environment's (`.lumenTopBarPlacement`, `.unified` by default).
    let placement: LumenTopBarPlacement?

    @Environment(\.lumenTopBarPlacement) private var environmentPlacement
    @Environment(\.lumenMetrics) private var metrics
    @Environment(\.lumenPalette) private var palette
    @State private var bandHeight: CGFloat = 0
    @State private var barWidth: CGFloat = 0

    func body(content: Content) -> some View {
        switch placement ?? environmentPlacement {
        case .underTitleBar: underTitleBar(content)
        case .unified: unified(content)
        }
    }

    private func reported(_ bar: some View) -> some View {
        bar.background {
            GeometryReader { proxy in
                Color.clear.preference(key: LumenTopBarFrameKey.self, value: proxy.frame(in: .global))
            }
        }
    }

    private func underTitleBar(_ content: Content) -> some View {
        // A real row, not a safe-area inset: AppKit-backed split views ignore SwiftUI's insets and
        // would draw under the bar. The bar is sized first; the content takes exactly the space under
        // it (any minimum height) and anything taller is clipped at the bottom, so nothing can push
        // the bar up or slide under it.
        VStack(spacing: 0) {
            reported(bar.lumenWrapsWithoutTruncating())
                .layoutPriority(1)
            content
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
                .clipped()
        }
        .preference(key: LumenTopBarPlacementKey.self, value: .underTitleBar)
    }

    private func unified(_ content: Content) -> some View {
        // Unified: the bar's content is handed to the window's toolbar (`LumenTopBar` turns into
        // toolbar items), so AppKit puts it on the window buttons' center line in the compact band and
        // owns clicks, dragging and double-click. Here, only what's behind and under it: Lumen's glow
        // filling the band (the toolbar's own background hidden) and the hairline under it. The
        // content starts under the hairline, clipped.
        VStack(spacing: 0) {
            bar.environment(\.lumenTopBarHostsInToolbar, true)
                .environment(\.lumenTopBarWidth, barWidth > 0 ? barWidth : nil)
            // The hairline as its own row: content whose top edge touched the band's edge would count
            // as adjacent to the safe area, and SwiftUI stretches AppKit-backed content (HSplitView's
            // NSSplitView) up into it, hiding the panes' top under the toolbar.
            Rectangle().fill(palette[.borderSubtle]).frame(height: metrics.stroke.hairline)
            content
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
                .clipped()
        }
        .background {
            // The band's height: the safe area's top inset at the window's content edge.
            GeometryReader { proxy in Color.clear.preference(key: LumenBandHeightKey.self, value: proxy.safeAreaInsets.top) }
        }
        .onPreferenceChange(LumenBandHeightKey.self) { value in MainActor.assumeIsolated { bandHeight = value } }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { barWidth = $0 }
        .background(alignment: .top) {
            LumenTitlebarBackground()
                .frame(height: bandHeight)
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(key: LumenTopBarFrameKey.self, value: bandHeight > 0 ? proxy.frame(in: .global) : nil)
                    }
                }
                .ignoresSafeArea(.container, edges: .top)
                .accessibilityHidden(true)
        }
        .toolbarBackground(.hidden, for: .windowToolbar)
        .modifier(LumenToolbarTitleRemoval())
        .preference(key: LumenTopBarPlacementKey.self, value: .unified)
    }
}

/// The title bar band's height, as the unified placement measures it.
private struct LumenBandHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

extension View {
    /// The top-bar rule `LumenWorkspaceWindow` and `.lumenTopBar` share.
    func lumenPinnedTopBar<Bar: View>(_ bar: Bar, placement: LumenTopBarPlacement? = nil) -> some View {
        modifier(LumenPinnedTopBar(bar: bar, placement: placement))
    }

    /// A workspace region: always mounted, zero-sized while hidden, never taller than it's given.
    /// `name` is how a column-overflow report names it (PRINCIPLES §6); a hidden region isn't watched.
    func lumenWorkspaceRegion(_ name: String, shown: Bool, width: (min: CGFloat, ideal: CGFloat, max: CGFloat)? = nil,
                              height: (min: CGFloat, ideal: CGFloat)? = nil) -> some View {
        self
            .lumenColumnWidthWatch(name, isActive: shown)
            .modifier(LumenRegionTopReporter())
            .frame(minWidth: width.map { shown ? $0.min : 0 }, idealWidth: width.map { shown ? $0.ideal : 0 },
                   maxWidth: width.map { shown ? $0.max : 0 } ?? .infinity,
                   minHeight: height.map { shown ? $0.min : 0 } ?? 0, idealHeight: height.map { shown ? $0.ideal : 0 },
                   maxHeight: height == nil || shown ? .infinity : 0, alignment: .top)
            .clipped()
            .opacity(shown ? 1 : 0)
            .allowsHitTesting(shown)
            .accessibilityHidden(!shown)
            // A hidden region stays mounted at zero size; its labels and tiles aren't on screen, so
            // they don't report to the conformance checks.
            .transformPreference(LumenTruncationKey.self) { if !shown { $0 = [] } }
            .transformPreference(LumenIconScaleKey.self) { if !shown { $0 = [] } }
            .transformPreference(LumenOverflowKey.self) { if !shown { $0 = [] } }
            .transformPreference(LumenBacklightKey.self) { if !shown { $0 = [] } }
    }
}

/// A workspace window: a top bar with the panel toggles at its trailing edge, a sidebar, the main content, an inspector, and a bottom panel under
/// the content. Hide and show panels through `panels`; the toggles, the View menu commands
/// (⌃⌘S, ⇧⌘Y, ⌥⌘I through `LumenViewCommands`) and the regions all follow it.
///
/// Use it with `.windowStyle(.hiddenTitleBar)`. Leave out a region the window doesn't have, and its
/// toggle is left out too.
///
/// The top bar is the unified row by default: its content becomes the window's own toolbar
/// items (`topLeading` and `topCenter` as `.navigation` items, `topTrailing` with the panel toggles
/// and New Tab as a `.primaryAction` item), on the window buttons' center line, over Lumen's title
/// bar glow. Give the scene the compact band:
///
/// ```swift
/// Window("Workspace", id: "workspace") { WorkspaceView() }
///     .windowStyle(.hiddenTitleBar)
///     .windowToolbarStyle(.unifiedCompact(showsTitle: false))
/// ```
///
/// `.topBarPlacement(.underTitleBar)` keeps MacScope's earlier look, a SwiftUI bar under the window
/// buttons' own band. For the arrangement put `LumenWorkspaceToolbar`
/// in `topLeading` and `LumenToolbarStatus` in `topCenter`, and give the content a
/// `LumenContentTabBar` for its editor modes or tabs.
public struct LumenWorkspaceWindow<Leading: View, Center: View, Trailing: View, Sidebar: View, Content: View,
                                   Inspector: View, Bottom: View>: View {
    @Binding private var panels: LumenWorkspacePanels
    private let topLeading: Leading
    private let topCenter: Center
    private let topTrailing: Trailing
    private let sidebar: Sidebar
    private let content: Content
    private let inspector: Inspector
    private let bottom: Bottom
    private var wash: LumenAmbientWash = .falling
    private var embeddedBottom: Binding<Bool>?
    private var shortcuts: LumenViewShortcuts = .standard
    private var sidebarWidth = LumenLayout.sidebarColumn
    private var inspectorWidth = LumenLayout.inspectorColumn
    private var contentMinWidth: CGFloat = 320
    private var placement: LumenTopBarPlacement?
    private var newItem: (title: String, action: () -> Void)?

    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenMetrics) private var metrics

    /// - Parameters:
    ///   - panels: which panels show.
    ///   - content: the main content, between the sidebar and the inspector, over the bottom panel.
    ///   - sidebar, inspector, bottom: the panels; leave one out (`EmptyView`) when the window
    ///     doesn't have it, and its toggle is left out too.
    ///   - topLeading, topCenter, topTrailing: the top bar's content; the panel toggles follow the
    ///     trailing content.
    public init(panels: Binding<LumenWorkspacePanels>,
                @ViewBuilder content: () -> Content,
                @ViewBuilder sidebar: () -> Sidebar = { EmptyView() },
                @ViewBuilder inspector: () -> Inspector = { EmptyView() },
                @ViewBuilder bottom: () -> Bottom = { EmptyView() },
                @ViewBuilder topLeading: () -> Leading,
                @ViewBuilder topCenter: () -> Center = { EmptyView() },
                @ViewBuilder topTrailing: () -> Trailing = { EmptyView() }) {
        _panels = panels
        self.content = content()
        self.sidebar = sidebar()
        self.inspector = inspector()
        self.bottom = bottom()
        self.topLeading = topLeading()
        self.topCenter = topCenter()
        self.topTrailing = topTrailing()
    }

    /// The window's warm tint (`.falling`, the title bar's glow reaching down, by default); `.none`
    /// turns it off.
    public func ambientWash(_ wash: LumenAmbientWash) -> Self {
        var copy = self
        copy.wash = wash
        return copy
    }

    /// A bottom panel the content draws itself (one built from state the content owns): the window
    /// adds the bottom toggle and ⇧⌘Y for it, in the order, but no bottom region. Ignored when
    /// the window has its own `bottom`.
    public func bottomPanelToggle(_ isPresented: Binding<Bool>) -> Self {
        var copy = self
        copy.embeddedBottom = isPresented
        return copy
    }

    /// The panel shortcuts the toggles' help tags name, when the app's menu uses its own (or the
    /// user's rebound) set rather than `LumenViewShortcuts.standard`.
    public func panelShortcuts(_ shortcuts: LumenViewShortcuts) -> Self {
        var copy = self
        copy.shortcuts = shortcuts
        return copy
    }

    /// Where the top bar sits: `.unified` (the default unless `.lumenTopBarPlacement` says
    /// otherwise) or `.underTitleBar` (a SwiftUI bar under the window buttons' band).
    public func topBarPlacement(_ placement: LumenTopBarPlacement) -> Self {
        var copy = self
        copy.placement = placement
        return copy
    }

    /// The New Tab button (`LumenNewItemButton`) at the very end of the top bar, after the panel
    /// toggles. Attach a `.lumenLaunchMenu` by drawing the button in `topTrailing` instead. The title
    /// defaults to "New Tab", not the bare button's generic "New": in a workspace window it opens a tab.
    public func newItemButton(_ title: String = "New Tab", action: @escaping () -> Void) -> Self {
        var copy = self
        copy.newItem = (title, action)
        return copy
    }

    /// The sidebar's and inspector's widths, when the app's differ from Lumen's
    /// (`LumenLayout.sidebarColumn`, `LumenLayout.inspectorColumn`). Each starts at its ideal.
    public func columnWidths(sidebar: (min: CGFloat, ideal: CGFloat, max: CGFloat) = LumenLayout.sidebarColumn,
                             inspector: (min: CGFloat, ideal: CGFloat, max: CGFloat) = LumenLayout.inspectorColumn) -> Self {
        var copy = self
        copy.sidebarWidth = sidebar
        copy.inspectorWidth = inspector
        return copy
    }

    /// The editor column's minimum, including an embedded bottom panel. Include this width,
    /// the visible side columns and dividers in the scene's window minimum.
    public func contentMinimumWidth(_ width: CGFloat) -> Self {
        var copy = self
        copy.contentMinWidth = width.isFinite ? max(0, width) : 320
        return copy
    }

    private var hasSidebar: Bool { Sidebar.self != EmptyView.self }
    private var hasInspector: Bool { Inspector.self != EmptyView.self }
    private var hasBottom: Bool { Bottom.self != EmptyView.self }

    private func binding(_ path: WritableKeyPath<LumenWorkspacePanels, Bool>, present: Bool) -> Binding<Bool>? {
        present ? Binding(get: { panels[keyPath: path] }, set: { panels[keyPath: path] = $0 }) : nil
    }

    public var body: some View {
        let leading = binding(\.leading, present: hasSidebar)
        let bottomToggle = hasBottom ? binding(\.bottom, present: true) : embeddedBottom
        let trailing = binding(\.trailing, present: hasInspector)
        HSplitView {
            if hasSidebar {
                sidebar
                    .lumenSidebarBackground()
                    .lumenWorkspaceRegion("Sidebar", shown: panels.leading, width: sidebarWidth)
            }
            VSplitView {
                content
                    .lumenColumnWidthWatch("Content", isActive: true)
                    .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
                    .clipped()
                    .modifier(LumenRegionTopReporter())
                if hasBottom {
                    bottom.lumenWorkspaceRegion("Bottom panel", shown: panels.bottom, height: (min: 120, ideal: 220))
                }
            }
            .frame(minWidth: contentMinWidth, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
            .layoutPriority(1)
            if hasInspector {
                inspector.lumenWorkspaceRegion("Inspector", shown: panels.trailing, width: inspectorWidth)
            }
        }
        .background(palette[.bgCanvas])
        .lumenPinnedTopBar(
            LumenTopBar {
                topLeading
            } center: {
                topCenter
            } trailing: {
                HStack(spacing: 8) {
                    topTrailing
                    // New Tab right beside the toggles, at their spacing.
                    HStack(spacing: metrics.spacing.s1) {
                        if leading != nil || bottomToggle != nil || trailing != nil {
                            LumenPanelToggles(leading: leading, bottom: bottomToggle, trailing: trailing, shortcuts: shortcuts, registersShortcuts: false)
                        }
                        if let newItem {
                            LumenNewItemButton(newItem.title, action: newItem.action)
                        }
                    }
                }
            },
            placement: placement
        )
        .lumenAmbientWash(wash, strength: 0.09)
        .lumenPanelCommands(leading: leading, bottom: bottomToggle, trailing: trailing)
    }
}

// MARK: Ambient wash

/// A subtle tint of the theme's accent over a whole window, for themes that want warmth (Midnight's
/// pink glow). It sits over every surface without blocking clicks and stays faint enough that text
/// contrast holds.
public enum LumenAmbientWash: String, CaseIterable, Sendable {
    /// No tint.
    case none
    /// The accent rising from the bottom edge and fading out toward the top.
    case rising
    /// The title bar's glow reaching down into the window, fading out by its middle.
    case falling
    /// The accent gathered in the bottom corners, as light pooling.
    case pooled
}

private struct LumenAmbientWashModifier: ViewModifier {
    let wash: LumenAmbientWash
    let strength: Double
    @Environment(\.lumenPalette) private var palette

    func body(content: Content) -> some View {
        content.overlay {
            Group {
                switch wash {
                case .none:
                    EmptyView()
                case .rising:
                    LinearGradient(stops: [.init(color: palette[.accent].opacity(strength), location: 0),
                                           .init(color: palette[.accent].opacity(strength * 0.35), location: 0.45),
                                           .init(color: .clear, location: 1)],
                                   startPoint: .bottom, endPoint: .top)
                case .falling:
                    LinearGradient(stops: [.init(color: palette[.titlebarActiveTop].opacity(strength * 4), location: 0),
                                           .init(color: palette[.accent].opacity(strength * 0.6), location: 0.25),
                                           .init(color: .clear, location: 0.6)],
                                   startPoint: .top, endPoint: .bottom)
                case .pooled:
                    ZStack {
                        RadialGradient(colors: [palette[.accent].opacity(strength * 1.4), .clear], center: .bottomLeading, startRadius: 0, endRadius: 700)
                        RadialGradient(colors: [palette[.accent].opacity(strength * 1.1), .clear], center: .bottomTrailing, startRadius: 0, endRadius: 600)
                    }
                }
            }
            .blendMode(.plusLighter)
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

public extension View {
    /// Tints the whole window faintly with the theme's accent. Apply to the window's root view.
    /// - Parameter strength: the tint's strongest opacity; 0.06–0.12 keeps text contrast intact.
    func lumenAmbientWash(_ wash: LumenAmbientWash, strength: Double = 0.08) -> some View {
        modifier(LumenAmbientWashModifier(wash: wash, strength: strength))
    }
}

import AppKit
import SwiftUI
import LumenTokens

// Windows that draw their own structure: a hidden title bar with the app's top bar, and HSplitView
// columns instead of NavigationSplitView and `.inspector` (MacScope's structure). The same visual
// language as the toolbar-based workspace, and the same rule: every column declares its minimum,
// and the window's minimum is their sum (PRINCIPLES §6).

extension LumenLayout {
    /// A navigator or sidebar column's widths, for HSplitView panes and NavigationSplitView alike.
    public static let sidebarColumn: (min: CGFloat, ideal: CGFloat, max: CGFloat) = (200, 240, 320)
    /// The space macOS's window buttons take at the leading edge of a hidden title bar.
    public static let windowButtonsInset: CGFloat = 78
    /// A custom top bar's height, under the window buttons' band (MacScope's is 46).
    public static let topBarHeight: CGFloat = 44
}

public extension View {
    /// Makes this view a split view column with a declared width range: HSplitView keeps the column
    /// at least `min` wide, and the window can't shrink below its columns' minimums.
    func lumenColumn(min: CGFloat, ideal: CGFloat? = nil, max: CGFloat? = nil) -> some View {
        lumenColumn("Column", min: min, ideal: ideal, max: max)
    }

    /// Paints a NavigationSplitView sidebar (or any list) in the theme's `sidebar.background` instead of
    /// the system's translucent gray material, as MacScope's sidebar is. Apply to the sidebar's content.
    func lumenSidebarBackground() -> some View {
        modifier(LumenSidebarBackgroundModifier())
    }

    /// A sidebar column (`LumenLayout.sidebarColumn`) on `sidebar.background`.
    func lumenSidebarColumn() -> some View {
        modifier(LumenSidebarColumnModifier())
    }
}

extension View {
    /// A split-view column that reports content wider than itself as `name` (PRINCIPLES §6).
    func lumenColumn(_ name: String, min: CGFloat, ideal: CGFloat?, max: CGFloat?) -> some View {
        lumenColumnWidthWatch(name, isActive: true)
            .frame(minWidth: min, idealWidth: ideal ?? min, maxWidth: max ?? .infinity, maxHeight: .infinity)
    }
}

private struct LumenSidebarBackgroundModifier: ViewModifier {
    @Environment(\.lumenPalette) private var palette
    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .background(palette[.sidebarBackground])
    }
}

private struct LumenSidebarColumnModifier: ViewModifier {
    @Environment(\.lumenPalette) private var palette
    func body(content: Content) -> some View {
        content
            .lumenColumn("Sidebar", min: LumenLayout.sidebarColumn.min, ideal: LumenLayout.sidebarColumn.ideal, max: LumenLayout.sidebarColumn.max)
            .scrollContentBackground(.hidden)
            .background(palette[.sidebarBackground])
    }
}

/// An inspector as an HSplitView column, for windows that don't use `.inspector`: the inspector's
/// sections at `LumenLayout.inspectorColumn` widths. Show and hide it by including it or not, and
/// pair it with `LumenInspectorToggle`.
public struct LumenInspectorPane<Content: View>: View {
    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        LumenInspector { content }
            .lumenColumn("Inspector", min: LumenLayout.inspectorColumn.min, ideal: LumenLayout.inspectorColumn.ideal,
                         max: LumenLayout.inspectorColumn.max)
    }
}

// MARK: Top bar

/// The app's own top bar under a hidden title bar (`.windowStyle(.hiddenTitleBar)`; place it with
/// `.lumenTopBar { }`):
/// leading, center and trailing content on the title bar glow, with a hairline below. Placed with
/// `.lumenTopBar` (or in a `LumenWorkspaceWindow`) it's the unified row by default: its leading
/// content and center become the window toolbar's `.navigation` items and its trailing content a
/// `.primaryAction` item, so they sit on the window buttons' center line in AppKit's compact band
/// (give the scene `.windowToolbarStyle(.unifiedCompact(showsTitle: false))`). With
/// `.lumenTopBarPlacement(.underTitleBar)` it's a SwiftUI row under the window buttons' band,
/// inside the same glow, as MacScope's top bar had it; dragging it moves the window and
/// double-clicking it does what System Settings › Desktop & Dock says (zoom or minimize), as a real
/// title bar does.
///
/// The leading and trailing content keep their size; the center gives way first (truncating), so the
/// bar's minimum width is the leading and trailing content plus the window buttons.
public struct LumenTopBar<Leading: View, Center: View, Trailing: View>: View {
    private let leading: Leading
    private let center: Center
    private let trailing: Trailing

    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenMetrics) private var metrics
    @Environment(\.lumenTopBarHostsInToolbar) private var hostsInToolbar
    @Environment(\.lumenTopBarWidth) private var barWidth
    @State private var leadingWidth: CGFloat = 0
    @State private var trailingWidth: CGFloat = 0

    public init(@ViewBuilder leading: () -> Leading, @ViewBuilder center: () -> Center, @ViewBuilder trailing: () -> Trailing) {
        self.leading = leading()
        self.center = center()
        self.trailing = trailing()
    }

    public var body: some View {
        if hostsInToolbar {
            // Nothing in the content: the items live in the window's toolbar, which AppKit lays out on
            // the window buttons' center line.
            Color.clear.frame(width: 0, height: 0)
                .background {
                    LumenToolbarPriorities(hasCenter: Center.self != EmptyView.self).frame(width: 0, height: 0)
                }
                .accessibilityHidden(true)
                .toolbar { toolbarItems }
        } else {
            row
        }
    }

    /// Leading content, the status, and the trailing panels as three items. AppKit sizes each SwiftUI
    /// item at its ideal width (it can't be made flexible) and, short of room, drops items whole, last
    /// first and never back into the overflow menu; so the status goes first (`LumenToolbarPriorities`
    /// gives it the low visibility priority) and the panels and leading content are kept.
    @ToolbarContentBuilder private var toolbarItems: some ToolbarContent {
        if #available(macOS 26, *) {
            // Bare on the glow: no shared glass platter behind them.
            ToolbarItem(placement: .navigation) { leadingItem }.sharedBackgroundVisibility(.hidden)
            if Center.self != EmptyView.self {
                ToolbarItem(placement: .navigation) { centerItem }.sharedBackgroundVisibility(.hidden)
            }
            ToolbarSpacer(.flexible)
            ToolbarItem(placement: .primaryAction) { trailingItem }.sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .navigation) { leadingItem }
            if Center.self != EmptyView.self {
                ToolbarItem(placement: .navigation) { centerItem }
            }
            ToolbarItem(placement: .primaryAction) { trailingItem }
        }
    }

    private func compact(_ item: some View) -> some View {
        item.fixedSize().environment(\.lumenToolbarCompact, true)
    }

    private var leadingItem: some View {
        compact(leading).onGeometryChange(for: CGFloat.self) { $0.size.width } action: { leadingWidth = $0 }
    }

    private var trailingItem: some View {
        // A trailing gutter to match the leading items' clearance of the window buttons: AppKit
        // alone leaves about 8 pt, which put the last button against the window's corner.
        compact(trailing).padding(.trailing, Self.trailingGutter).onGeometryChange(for: CGFloat.self) { $0.size.width } action: { trailingWidth = $0 }
    }

    /// The status, told how much room the window leaves it: the window less the window buttons'
    /// inset, the leading and trailing items and AppKit's spacing around the three items.
    private var centerItem: some View {
        let room = barWidth.flatMap { width -> CGFloat? in
            guard leadingWidth > 0, trailingWidth > 0 else { return nil }
            return max(width - Self.toolbarLeadingInset - leadingWidth - trailingWidth - Self.toolbarSpacing, 0)
        }
        return compact(center).environment(\.lumenToolbarStatusRoom, room)
    }

    /// Added to AppKit's own trailing margin, for about 12 pt from the window's edge.
    static var trailingGutter: CGFloat { LumenMetrics.standard.spacing.s2 }

    /// Where AppKit starts the toolbar's items, past the window buttons (85 pt measured on macOS 27).
    private static var toolbarLeadingInset: CGFloat { 90 }
    /// AppKit's spacing between the three items and at the trailing edge, with a margin.
    private static var toolbarSpacing: CGFloat { 40 }

    private var row: some View {
        HStack(spacing: metrics.spacing.s5) {
            leading.fixedSize()
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(key: LumenTopBarContentFrameKey.self, value: proxy.frame(in: .global))
                    }
                }
            Spacer(minLength: metrics.spacing.s4)
            center.layoutPriority(-1)
            Spacer(minLength: metrics.spacing.s4)
            trailing.fixedSize()
        }
        .padding(.horizontal, metrics.spacing.s4)
        .frame(height: LumenLayout.topBarHeight)
        .frame(maxWidth: .infinity)
        .background {
            // The glow (and dragging) also fill the window buttons' band above the bar; only the
            // background extends there, so the bar's content always stays inside the window.
            LumenTitlebarBackground()
                .overlay(LumenWindowDragArea())
                .ignoresSafeArea(.container, edges: .top)
        }
        .overlay(alignment: .bottom) { Rectangle().fill(palette[.borderSubtle]).frame(height: metrics.stroke.hairline) }
        .accessibilityElement(children: .contain)
    }
}

public extension View {
    /// Puts `bar` (a `LumenTopBar`) at the top of a hidden-title-bar window, with the content under
    /// it. By default (`.unified`) the bar's content becomes the window's own toolbar items,
    /// on the window buttons' center line, over Lumen's title bar glow; give the scene
    /// `.windowToolbarStyle(.unifiedCompact(showsTitle: false))` for the compact band. With `.lumenTopBarPlacement(.underTitleBar)` (MacScope's
    /// a SwiftUI bar under the window buttons' band) the window buttons keep their band at the top and the bar sits under it, its
    /// glow reaching up behind them. Either way the content starts under the bar and can never push it
    /// off screen. Apply to the window's root view.
    func lumenTopBar<Bar: View>(@ViewBuilder _ bar: () -> Bar) -> some View {
        // Pinned in the top safe area, with the content clipped to the space under it: content that
        // asks for more height (a collapsing split view, say) can never push the bar off screen.
        lumenPinnedTopBar(bar())
    }
}

public extension LumenTopBar where Center == EmptyView {
    init(@ViewBuilder leading: () -> Leading, @ViewBuilder trailing: () -> Trailing) {
        self.init(leading: leading, center: { EmptyView() }, trailing: trailing)
    }
}

/// An area that behaves like a title bar: drag to move the window, double-click for the user's
/// title bar action. Put it behind custom title bar content.
public struct LumenWindowDragArea: NSViewRepresentable {
    public init() {}
    public func makeNSView(context: Context) -> NSView { DragView() }
    public func updateNSView(_ nsView: NSView, context: Context) {}

    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }

        override func mouseDown(with event: NSEvent) {
            guard event.clickCount == 2, let window else {
                super.mouseDown(with: event)
                return
            }
            // System Settings › Desktop & Dock › "Double-click a window's title bar to".
            switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
            case "Minimize": window.performMiniaturize(nil)
            case "None": break
            default: window.performZoom(nil)
            }
        }
    }
}

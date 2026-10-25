import AppKit
import SwiftUI
import LumenTokens

// The top bar: one compact row. The window buttons and every item share
// one center line, and there's no band above or below it. Editor modes move out of the bar into the
// content pane's own tab bar (`LumenContentTabBar`).
//
// How: the bar is hosted natively, as a native NSToolbar app
// hosts its own. Its leading content and status become `.navigation` toolbar items and its trailing
// content a `.primaryAction` item of the window's real toolbar; the scene uses
// `.windowToolbarStyle(.unifiedCompact(showsTitle: false))`, so AppKit sizes the band (38–40 pt),
// centers the window buttons and the items on one line, and handles clicks, dragging and
// double-click. The toolbar's own background is hidden and Lumen's title bar glow is drawn behind it.

/// Where a workspace window's top bar sits.
public enum LumenTopBarPlacement: String, CaseIterable, Sendable {
    /// The default: the bar's content as the window's own toolbar items, one compact row with the window
    /// buttons on the same center line. The scene needs
    /// `.windowToolbarStyle(.unifiedCompact(showsTitle: false))`.
    case unified
    /// A SwiftUI bar under the window buttons' own band, its glow reaching up
    /// behind them.
    case underTitleBar
}

public extension LumenLayout {
    /// The unified top bar's height: AppKit's `.unifiedCompact` band, 40 pt on macOS 27 (38 on
    /// macOS 14–26). The window's own band is what counts: the unified placement measures it and
    /// counts it in the window's minimum height.
    static let unifiedTopBarHeight: CGFloat = 40
}

/// The top bar's placement (`LumenWorkspaceWindow`, `.lumenTopBar`), reported for
/// `LumenConformance.workspaceWindow`. A bar that reports none is checked as `.underTitleBar`.
public struct LumenTopBarPlacementKey: PreferenceKey {
    public static let defaultValue: LumenTopBarPlacement? = nil
    public static func reduce(value: inout LumenTopBarPlacement?, nextValue: () -> LumenTopBarPlacement?) { value = nextValue() ?? value }
}

/// The frame of a top bar's content (global coordinates; `LumenTopBar` reports its leading content
/// when it draws in the window's content), for `LumenConformance.workspaceWindow`: it must not reach
/// under the window buttons. A toolbar-hosted bar's items live in the toolbar and report nothing here.
public struct LumenTopBarContentFrameKey: PreferenceKey {
    public static let defaultValue: CGRect? = nil
    public static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) { value = nextValue() ?? value }
}

public extension View {
    /// Where `.lumenTopBar` (and a `LumenWorkspaceWindow` inside this view) puts its bar:
    /// `.unified` or `.underTitleBar` (a SwiftUI bar under the window buttons' band).
    func lumenTopBarPlacement(_ placement: LumenTopBarPlacement) -> some View {
        environment(\.lumenTopBarPlacement, placement)
    }
}

extension EnvironmentValues {
    @Entry var lumenTopBarPlacement: LumenTopBarPlacement = .unified
    /// Set by the unified placement: `LumenTopBar` hands its content to the window's toolbar.
    @Entry var lumenTopBarHostsInToolbar = false
    /// Inside a toolbar-hosted bar: pieces take the compact sizes (a 20 pt tile, a 13 pt name over
    /// an 11 pt subtitle) so they fit the compact band.
    @Entry var lumenToolbarCompact = false
    /// The window's width, from the unified placement's own layout, for the bar's toolbar budget.
    @Entry var lumenTopBarWidth: CGFloat? = nil
    /// The width the unified bar's toolbar leaves for the status: the window less the window buttons,
    /// the leading and trailing items and AppKit's spacing; `nil` until measured. Worked out in
    /// SwiftUI's layout as the window resizes, so the toolbar doesn't overflow (an overflowing toolbar
    /// collapses its flexible space and the panels slide left).
    @Entry var lumenToolbarStatusRoom: CGFloat? = nil
}

/// Sets which of the unified bar's toolbar items AppKit gives up first when the window is too narrow:
/// the status (temporary, like the indicators) at `.low`, the leading content and the trailing
/// panels at `.high`. AppKit otherwise drops the last item, the panels, and a dropped SwiftUI item
/// doesn't come back through the overflow menu. It also counts the title bar band in the window's
/// minimum height (`countBandInMinimum`): the minimum an app declares is its content's. That
/// adjustment belongs to the window, not to one view: a remounted bar doesn't add the band again, and
/// the last bar to leave a window (the placement turned to `.underTitleBar`) takes it back out.
struct LumenToolbarPriorities: NSViewRepresentable {
    let hasCenter: Bool

    func makeNSView(context: Context) -> PriorityView { PriorityView() }

    static func dismantleNSView(_ nsView: PriorityView, coordinator: ()) {
        NotificationCenter.default.removeObserver(nsView)
        nsView.releaseWindow()
    }

    /// What the bars on one window added to its minimum height.
    final class BandMinimum {
        /// The bar views on the window; the last to leave takes the band back out.
        var owners = 0
        /// The minimum height we last gave the window, so the band isn't counted twice.
        var minimumWeSet: CGFloat?
        /// The band we added to reach it.
        var band: CGFloat = 0
    }

    /// Per window, held only while the window lives.
    @MainActor static let bandMinimums = NSMapTable<NSWindow, BandMinimum>.weakToStrongObjects()

    func updateNSView(_ nsView: PriorityView, context: Context) {
        nsView.hasCenter = hasCenter
        nsView.schedule()
    }

    final class PriorityView: NSView {
        var hasCenter = false

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        private weak var observed: NSWindow?
        /// The window whose `BandMinimum` this view counts itself an owner of.
        private weak var owned: NSWindow?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if owned !== window {
                releaseWindow()
                if let window {
                    let record = LumenToolbarPriorities.bandMinimums.object(forKey: window) ?? BandMinimum()
                    record.owners += 1
                    LumenToolbarPriorities.bandMinimums.setObject(record, forKey: window)
                    owned = window
                }
            }
            if let window, observed !== window {
                NotificationCenter.default.removeObserver(self)
                observed = window
                // SwiftUI rebuilds toolbar items as their content changes; set the priorities again
                // as the window resizes, when they matter.
                for name in [NSWindow.willStartLiveResizeNotification, NSWindow.didResizeNotification] {
                    NotificationCenter.default.addObserver(self, selector: #selector(windowChanged), name: name, object: window)
                }
            }
            schedule()
        }

        @objc private func windowChanged(_ note: Notification) { apply(); countBandInMinimum() }

        func schedule() {
            // The toolbar's items exist once SwiftUI has installed them, after this update.
            DispatchQueue.main.async { [weak self] in self?.apply(); self?.countBandInMinimum() }
        }

        /// Leaves the window's `BandMinimum`; the last owner out takes the band back out of the
        /// minimum, unless SwiftUI has set the minimum afresh since.
        func releaseWindow() {
            guard let window = owned else { return }
            owned = nil
            guard let record = LumenToolbarPriorities.bandMinimums.object(forKey: window) else { return }
            record.owners -= 1
            guard record.owners <= 0 else { return }
            LumenToolbarPriorities.bandMinimums.removeObject(forKey: window)
            if let set = record.minimumWeSet, abs(window.contentMinSize.height - set) < 0.5 {
                var minimum = window.contentMinSize
                minimum.height -= record.band
                window.contentMinSize = minimum
            }
        }

        /// Counts the title bar band in the window's minimum height. SwiftUI sets the window's
        /// minimum from the content's (an app's `.frame(minHeight:)`), but the content lays out under
        /// the band: a window at that minimum centered the taller content and slid it up under the
        /// toolbar, half-collapsing the band. So the minimum an app declares is the
        /// content's, and the band is added here whenever SwiftUI (re)sets it.
        func countBandInMinimum() {
            guard let window, owned === window, let record = LumenToolbarPriorities.bandMinimums.object(forKey: window) else { return }
            let band = window.frame.height - window.contentLayoutRect.height
            guard band > 0.5 else { return }
            var minimum = window.contentMinSize
            if let set = record.minimumWeSet, abs(minimum.height - set) < 0.5 { return }
            minimum.height += band
            record.minimumWeSet = minimum.height
            record.band = band
            window.contentMinSize = minimum
            if window.contentLayoutRect.height + 0.5 < minimum.height - band {
                // Already under it (the window opened at the old minimum): grow to fit.
                var frame = window.frame
                let grow = minimum.height - band - window.contentLayoutRect.height
                frame.size.height += grow
                frame.origin.y -= grow
                window.setFrame(frame, display: true)
            }
        }

        private func apply() {
            guard let toolbar = window?.toolbar else { return }
            let hosted = toolbar.items.filter { $0.view != nil }
            let status = hasCenter && hosted.count >= 3 ? hosted[1] : nil
            // Everything else stays, the flexible space included (it keeps the panels at the
            // trailing edge once the status is gone).
            for item in toolbar.items {
                let priority: NSToolbarItem.VisibilityPriority = item === status ? .low : .high
                if item.visibilityPriority != priority { item.visibilityPriority = priority }
            }
        }
    }
}

/// Hides the window toolbar's own title where the OS lets a view do it (the scene's
/// `.windowToolbarStyle(.unifiedCompact(showsTitle: false))` covers older systems).
struct LumenToolbarTitleRemoval: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content.toolbar(removing: .title)
        } else {
            content
        }
    }
}

// MARK: the arrangement

/// The slanted hairline between a toolbar's groups, as is usual between the project, the tasks
/// and the status.
public struct LumenToolbarDivider: View {
    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenMetrics) private var metrics
    @Environment(\.lumenToolbarCompact) private var compact

    public init() {}

    public var body: some View {
        Rectangle()
            .fill(palette[.borderDefault])
            .frame(width: metrics.stroke.hairline, height: compact ? 18 : 22)
            .rotationEffect(.degrees(18))
            .padding(.horizontal, metrics.spacing.s1)
            .accessibilityHidden(true)
    }
}

/// The toolbar, leading part: the app mark (opens the launcher), a slash, the project (its tile,
/// name and branch or location; `LumenToolbarIdentity`), a slash, then the task controls
/// (`LumenTaskCluster`) with the task configuration pop-up after them. Put it in a
/// `LumenWorkspaceWindow`'s `topLeading` (or a `LumenTopBar`'s `leading`), with
/// `LumenToolbarStatus` in the center slot; the panel toggles and New Tab follow at the trailing edge.
///
/// ```swift
/// LumenWorkspaceWindow(panels: $panels) { … } topLeading: {
///     LumenWorkspaceToolbar {
///         Button { showsLauncher = true } label: { LumenIconTile("scope", hue: .huePink, size: 20) }
///     } project: {
///         LumenToolbarIdentity("vim", subtitle: "arm64e · Mach-O executable", systemImage: "doc.fill", hue: .hueOrange)
///     } tasks: {
///         LumenTaskCluster(tasks, activity: activity)
///     } configuration: {
///         LumenPopUpLabel("arm64e", symbol: "cpu")
///     }
/// } topCenter: {
///     LumenToolbarStatus(activity)
/// }
/// .newItemButton("New Tab") { … }
/// ```
public struct LumenWorkspaceToolbar<AppMark: View, Project: View, Tasks: View, Configuration: View>: View {
    private let appMark: AppMark
    private let project: Project
    private let tasks: Tasks
    private let configuration: Configuration

    @Environment(\.lumenMetrics) private var metrics

    /// Leave out a slot the app doesn't have (`EmptyView`), and its slash goes with it.
    public init(@ViewBuilder appMark: () -> AppMark = { EmptyView() },
                @ViewBuilder project: () -> Project,
                @ViewBuilder tasks: () -> Tasks = { EmptyView() },
                @ViewBuilder configuration: () -> Configuration = { EmptyView() }) {
        self.appMark = appMark()
        self.project = project()
        self.tasks = tasks()
        self.configuration = configuration()
    }

    public var body: some View {
        HStack(spacing: metrics.spacing.s4) {
            if AppMark.self != EmptyView.self {
                appMark
                LumenToolbarDivider()
            }
            project
            if Tasks.self != EmptyView.self || Configuration.self != EmptyView.self {
                LumenToolbarDivider()
                HStack(spacing: metrics.spacing.s4) {
                    tasks
                    if Tasks.self != EmptyView.self && Configuration.self != EmptyView.self { LumenToolbarDivider() }
                    configuration.fixedSize()
                }
            }
        }
        .fixedSize()
        .accessibilityElement(children: .contain)
    }
}

/// The temporary status indicators, for the top bar's center slot: a slash and the activity
/// capsule, left-aligned right after the leading groups (not centered), shown only while there's
/// something to say: work running, or its result. Idle, it's empty and the bar shows nothing there.
/// In the window toolbar it gives way first: it takes its preferred width (growing up to the room the
/// bar's fixed groups leave when its label is longer) and hides, rather than truncate, when its label
/// wouldn't fit whole; the trailing panels keep their place.
public struct LumenToolbarStatus: View {
    private let activity: LumenActivity?
    private let width: CGFloat

    @Environment(\.lumenMetrics) private var metrics
    @Environment(\.lumenToolbarCompact) private var compact
    @Environment(\.lumenToolbarStatusRoom) private var room
    @State private var needed: CGFloat = 0

    /// The narrowest the capsule gets before it hides (it's temporary; the panels matter more).
    static var minimumWidth: CGFloat { LumenActivityStatus.minimumWidth }

    /// - Parameter activity: what's happening; `nil` or `.idle` shows nothing.
    public init(_ activity: LumenActivity?, width: CGFloat = 300) {
        self.activity = activity
        self.width = width
    }

    private var shown: LumenActivity? {
        guard let activity else { return nil }
        if case .idle = activity { return nil }
        return activity
    }

    public var body: some View {
        if compact {
            // In the window toolbar: its preferred `width`, growing past it up to the room the other
            // items leave (less the slash) when the label is longer, and hidden when the label
            // wouldn't fit whole (PRINCIPLES §6: never truncated) or before the room is known.
            let available = room.map { $0 - metrics.spacing.s4 - 8 } ?? 0
            Group {
                if let shown, needed > 0, available >= max(Self.minimumWidth, needed) {
                    capsule(shown, width: min(available, max(width, needed)))
                } else {
                    Color.clear.frame(width: 0, height: 0)
                }
            }
            .background {
                if let shown { naturalWidth(of: shown) }
            }
        } else {
            // Fills the center slot so its content starts at the slot's leading edge, as is usual does.
            HStack(spacing: metrics.spacing.s4) {
                if let shown { capsule(shown, width: width) }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func capsule(_ activity: LumenActivity, width: CGFloat) -> some View {
        HStack(spacing: metrics.spacing.s4) {
            LumenToolbarDivider()
            LumenActivityStatus(activity, width: width)
        }
    }

    /// The capsule's width at its label's natural length (its mark, label and percentage, as
    /// `LumenActivityStatus` lays them out), measured without drawing.
    private func naturalWidth(of activity: LumenActivity) -> some View {
        HStack(spacing: metrics.spacing.s3) {
            Color.clear.frame(width: metrics.iconSize.regular, height: 1)
            Text(activity.label).font(metrics.typography.callout)
            if case .working(_, _?) = activity {
                Text("100%").font(metrics.typography.caption.monospacedDigit())
            }
        }
        .padding(.horizontal, metrics.spacing.s4)
        .fixedSize()
        .hidden()
        .accessibilityHidden(true)
        .background {
            GeometryReader { proxy in Color.clear.preference(key: LumenStatusWidthKey.self, value: proxy.size.width) }
        }
        .onPreferenceChange(LumenStatusWidthKey.self) { value in MainActor.assumeIsolated { needed = value } }
    }
}

private struct LumenStatusWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// The content pane's tab bar, at the top of the pane on the pane's own surface (PRINCIPLES §8: no
/// band of its own, a hairline under it): where editor tabs live and where a workspace's editor
/// modes go in the layout, out of the top bar. Put a `LumenModeSwitcher` (`.underline`) or a
/// `LumenDocumentTabBar` in it, and trailing actions after it.
///
/// ```swift
/// VStack(spacing: 0) {
///     LumenContentTabBar {
///         LumenModeSwitcher(selection: $mode, options: modes, style: .underline, title: \.title, systemImage: \.glyph)
///     }
///     editor
/// }
/// ```
public struct LumenContentTabBar<Tabs: View, Trailing: View>: View {
    private let tabs: Tabs
    private let trailing: Trailing

    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenMetrics) private var metrics

    public init(@ViewBuilder tabs: () -> Tabs, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.tabs = tabs()
        self.trailing = trailing()
    }

    /// The bar's height: Lumen's one tab-bar height (`layout.tabHeight`, 32 pt), shared with the
    /// document tab bar and the split panes' tab strips.
    public static var height: CGFloat { LumenMetrics.standard.layout.tabHeight }

    public var body: some View {
        HStack(spacing: metrics.spacing.s5) {
            tabs
            Spacer(minLength: metrics.spacing.s4)
            trailing.fixedSize()
        }
        .padding(.horizontal, metrics.spacing.s6)
        .frame(height: metrics.layout.tabHeight)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .bottom) { Rectangle().fill(palette[.borderSubtle]).frame(height: metrics.stroke.hairline) }
        .accessibilityElement(children: .contain)
    }
}

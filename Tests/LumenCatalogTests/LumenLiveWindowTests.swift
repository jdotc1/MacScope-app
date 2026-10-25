import AppKit
import SwiftUI
import XCTest
import LumenTokens
import LumenUI
import LumenConformance
@testable import LumenCatalog

/// The Catalog's windows as AppKit lays them out: real `NSWindow`s, never ordered on screen, with
/// the scene's toolbar bridged in, on the live code paths (no `lumenRendersOffscreen`). It catches what the summed-minimum layout checks and the
/// ImageRenderer goldens can't see: NavigationSplitView's real column widths, the unified band at
/// the window's minimum height, and the toolbar's status item.
///
/// `testCatalogSidebarKeepsItsMinimumAtTheWindowMinimum`, `testSplitWorkspaceTopBarKeepsItsBandAtTheMinimumSize`
/// and `testTopBarStatusNeverShowsTruncated` guard the sidebar minimum, the top bar's band and its status. Don't loosen them.
@MainActor
final class LumenLiveWindowTests: XCTestCase {
    static let registry = LumenRegistry(packs: [.core, .code])

    override class func setUp() {
        super.setUp()
        MainActor.assumeIsolated { LumenGlyph.register([.catalogPage]) }
    }

    /// What a window laid out: its top bar report, toolbar items, window buttons and split views.
    struct Layout {
        var bar: CGRect?
        var regionTop: CGFloat?
        var buttons: CGRect?
        /// Hosted toolbar items in order, with whether AppKit shows them.
        var items: [(frame: CGRect, visible: Bool)] = []
        /// Each NSSplitView (outermost first): its frame and its shown columns' frames, in window
        /// coordinates (x from the window's leading edge).
        var splits: [(frame: CGRect, columns: [CGRect])] = []
        var width: CGFloat = 0
        var hostFrame: CGRect = .zero
        var contentBounds: CGRect = .zero
        /// The window's content minimum, which AppKit takes from the hosted view when `sizing`
        /// includes `.minSize` (toolbar band included).
        var contentMinSize: CGSize = .zero
    }

    /// Lays `view` out in an offscreen window of `size` (`unified` for the split workspace's compact
    /// band, else the Catalog's `.unified` toolbar) and measures it.
    func layOut<V: View>(_ view: V, size: CGSize, compact: Bool, sizing: NSHostingSizingOptions = []) -> Layout {
        let store = LumenSnapshot.store(for: .init(themeID: LumenThemes.standardID, colorScheme: .dark), registry: Self.registry)
        return LumenThemeStore.withActiveStore(store) { () -> Layout in
            // The task-local override runs its body nonisolated; the test itself is on the main actor.
            MainActor.assumeIsolated { () -> Layout in
            var layout = Layout()
            let box = LiveLayoutBox()
            let root = view
                .lumenPaletteRoot(store: store)
                .lumenDensityRoot(store: store)
                .lumenMetrics(.standard)
                .onPreferenceChange(LumenTopBarFrameKey.self) { frame in MainActor.assumeIsolated { box.bar = frame } }
                .onPreferenceChange(LumenRegionTopKey.self) { top in MainActor.assumeIsolated { box.top = top } }
            let host = NSHostingView(rootView: AnyView(root))
            host.sizingOptions = sizing
            host.sceneBridgingOptions = [.toolbars, .title]
            let window = NSWindow(contentRect: CGRect(origin: .zero, size: size),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .darkAqua)
            window.titleVisibility = .hidden
            if compact {
                window.toolbarStyle = .unifiedCompact
                window.titlebarAppearsTransparent = true
            } else {
                window.toolbarStyle = .unified
            }
            window.contentView = host
            window.setContentSize(size)
            for _ in 0..<20 {
                (host.superview ?? host).layoutSubtreeIfNeeded(); window.displayIfNeeded()
                RunLoop.current.run(until: Date().addingTimeInterval(0.03))
            }
            let frameView = host.superview ?? host
            @MainActor func flip(_ rect: CGRect, from view: NSView) -> CGRect {
                var frame = frameView.convert(rect, from: view)
                if !frameView.isFlipped { frame.origin.y = frameView.bounds.height - frame.maxY }
                return frame
            }
            let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { type -> CGRect? in
                guard let button = window.standardWindowButton(type), !button.isHidden else { return nil }
                return flip(button.bounds, from: button)
            }
            layout.buttons = buttons.isEmpty ? nil : buttons.dropFirst().reduce(buttons[0]) { $0.union($1) }
            if let toolbar = window.toolbar {
                let visible = Set((toolbar.visibleItems ?? []).map(\.itemIdentifier))
                for item in toolbar.items {
                    guard let view = item.view else { continue }
                    let frame = view.window != nil ? flip(view.bounds, from: view) : .zero
                    layout.items.append((frame, visible.contains(item.itemIdentifier)))
                }
            }
            @MainActor func collect(_ view: NSView) {
                if let split = view as? NSSplitView {
                    layout.splits.append((split.convert(split.bounds, to: nil),
                                          split.arrangedSubviews.filter { !$0.isHidden }.map { $0.convert($0.bounds, to: nil) }))
                }
                view.subviews.forEach(collect)
            }
            collect(frameView)
            layout.width = size.width
            layout.hostFrame = host.frame
            layout.contentBounds = window.contentView?.bounds ?? .zero
            layout.bar = box.bar
            layout.regionTop = box.top
            layout.contentMinSize = window.contentMinSize
            window.close()
            return layout
            }
        }
    }

    // MARK: Catalog main window (L1)

    func catalog() -> some View {
        setenv("LUMEN_CATALOG_PAGE", "overview", 1)
        setenv("LUMEN_CATALOG_INSPECTOR", "1", 1)
        return CatalogView().modifier(CatalogWindowMinimum())
    }

    /// At the window's minimum width NavigationSplitView gave the inspector 240 (not its 220
    /// minimum) and took the 20 from the sidebar, which fell to 170 and cut its row labels at the
    /// leading edge ("verview"). The sidebar column must keep its declared minimum. The window's
    /// minimum is probed, not assumed: the toolbar band sits on top of the content's 640, so
    /// `windowMinWidth`×640 is a size the window can't reach (as with the Workspace window).
    func testCatalogSidebarKeepsItsMinimumAtTheWindowMinimum() throws {
        let minimum = layOut(catalog(), size: CGSize(width: 1280, height: 800), compact: false, sizing: [.minSize]).contentMinSize
        XCTAssertEqual(minimum.width, CatalogLayout.windowMinWidth, accuracy: 0.5, "the Catalog window's minimum width")
        XCTAssertGreaterThan(minimum.height, 640, "the toolbar band adds to the content's 640 pt minimum height")
        let layout = layOut(catalog(), size: minimum, compact: false)
        // Identify the sidebar by its leading column, independent of native split nesting.
        let split = try XCTUnwrap(layout.splits.filter { $0.columns.count >= 2 }
            .min { $0.columns[0].width < $1.columns[0].width }, "no split view")
        let geometry = "minimum: \(minimum); host: \(layout.hostFrame); content: \(layout.contentBounds); " + layout.splits.enumerated().map { index, split in
            "split \(index): \(split.frame); columns: \(split.columns)"
        }.joined(separator: "; ")
        // Measured on base: the split view is 970 pt wide in the 890 pt window (the inspector takes
        // its 280 ideal, not its 220 minimum), centered at x −40, so 40 pt of the 210 pt sidebar are
        // off the window's leading edge and 170 show.
        for measured in layout.splits {
            XCTAssertGreaterThanOrEqual(measured.frame.minX, -0.5, "the split view starts \(Int(-measured.frame.minX)) pt off the window's leading edge; \(geometry)")
            XCTAssertLessThanOrEqual(measured.frame.maxX, layout.width + 0.5, "the split view runs \(Int(measured.frame.maxX - layout.width)) pt past the window's trailing edge; \(geometry)")
        }
        let sidebar = split.columns[0]
        let shown = min(sidebar.maxX, layout.width) - max(sidebar.minX, 0)
        XCTAssertGreaterThanOrEqual(shown, CatalogLayout.sidebarMinWidth - 0.5,
                                    "\(Int(shown)) pt of the sidebar show at the \(Int(CatalogLayout.windowMinWidth)) pt window minimum; \(geometry)")

        if #available(macOS 27, *) {
            // Exercise the older-system composition here too; a current-system pass alone cannot
            // validate an availability-gated layout repair.
            let fallback = layOut(CatalogView(useLegacyColumns: true).modifier(CatalogWindowMinimum()),
                                  size: minimum, compact: false)
            let columns = try XCTUnwrap(fallback.splits.first { $0.columns.count == 3 }, "no three-column fallback split")
            let frames = "fallback split: \(columns.frame); columns: \(columns.columns)"
            XCTAssertGreaterThanOrEqual(columns.frame.minX, -0.5, frames)
            XCTAssertLessThanOrEqual(columns.frame.maxX, minimum.width + 0.5, frames)
            XCTAssertGreaterThanOrEqual(columns.columns[0].width, CatalogLayout.sidebarMinWidth - 0.5, frames)
            XCTAssertGreaterThanOrEqual(columns.columns[1].width, CatalogLayout.pageMinWidth - 0.5, frames)
            XCTAssertGreaterThanOrEqual(columns.columns[2].width, LumenLayout.inspectorColumn.min - 0.5, frames)
        }
    }

    // MARK: Split workspace, unified top bar

    func split(_ activity: LumenActivity? = nil) -> some View {
        Group {
            if let activity { SplitStatusHarness(activity: activity) } else { SplitWorkspaceDemo() }
        }
    }

    /// The Workspace window drew a blank body because its split view needed
    /// 1325 pt and sat centred in a 712 pt window, clipped at both ends (PRINCIPLES §6). At its real
    /// minimum and at a roomy size the split view must fill the window exactly. Hosted as the scene
    /// ships it (with its `minHeight: 660` frame), the window's minimum is probed, not assumed: the
    /// 52 pt toolbar band sits on top of the 660, so 1000×660 is a size the window can't reach.
    func testWorkspaceWindowFitsAtItsMinimumAndDefaultSize() throws {
        let workspace = { WorkspaceDemo().frame(minWidth: 1000, minHeight: 660) }
        let minimum = layOut(workspace(), size: CGSize(width: 1280, height: 800), compact: false, sizing: [.minSize]).contentMinSize
        XCTAssertEqual(minimum.width, 1000, accuracy: 0.5, "the Workspace window's minimum width")
        XCTAssertGreaterThan(minimum.height, 660, "the toolbar band adds to the content's 660 pt minimum height")
        for size in [minimum, CGSize(width: 1280, height: 800)] {
            let layout = layOut(workspace(), size: size, compact: false)
            let split = try XCTUnwrap(layout.splits.first, "no split view at \(size)")
            XCTAssertEqual(split.frame.minY, 0, accuracy: 0.5, "split view starts at y \(split.frame.minY) in a \(size) window")
            XCTAssertEqual(split.frame.height, size.height, accuracy: 0.5, "split view is \(split.frame.height) pt tall in a \(size) window")
        }
    }

    /// At the declared minimum (`SplitLayout.windowMinWidth` × `windowMinHeight`) the band must be as
    /// tall as at a roomy size and start at the window's top: the demo's minimum height applied
    /// under the toolbar's safe area, so below 640 SwiftUI centered the content and moved the band
    /// up by (640 − h) / 2, to 20 pt at 600, with the panes overlapping the toolbar row.
    func testSplitWorkspaceTopBarKeepsItsBandAtTheMinimumSize() throws {
        let roomy = layOut(split(), size: CGSize(width: 1280, height: 800), compact: true)
        let minimum = layOut(split(), size: CGSize(width: SplitLayout.windowMinWidth, height: SplitLayout.windowMinHeight), compact: true)
        let reference = try XCTUnwrap(roomy.bar, "the split workspace reports no top bar")
        let bar = try XCTUnwrap(minimum.bar, "the split workspace reports no top bar at its minimum")
        XCTAssertEqual(bar.minY, 0, accuracy: 0.5, "top bar starts at y \(bar.minY) at the minimum size")
        XCTAssertEqual(bar.height, reference.height, accuracy: 0.5, "band is \(bar.height) pt at the minimum size, \(reference.height) at 1280×800")
        if let top = minimum.regionTop {
            XCTAssertGreaterThanOrEqual(top, bar.maxY - 0.5, "a panel starts \(bar.maxY - top) pt under the top bar")
        }
        // The kit's own window check, at the same size.
        let findings = LumenConformance.workspaceWindow(sizes: [CGSize(width: SplitLayout.windowMinWidth, height: SplitLayout.windowMinHeight)],
                                                        panels: [LumenWorkspacePanels(leading: true, bottom: true, trailing: true)]) { _ in
            SplitWorkspaceDemo()
        }
        XCTAssertEqual(findings.map(\.description), [])
    }

    /// PRINCIPLES §9: the status capsule shows whole or hides; it never shows a truncated label
    /// (it stayed at its fixed 260 pt with 360 pt free and showed "Analysiere libsystem_kernel.dyl…").
    func testTopBarStatusNeverShowsTruncated() {
        let label = "Analysiere libsystem_kernel.dylib und alle abhängigen Bibliotheken"
        let needed = NSHostingController(rootView: Text(label).font(LumenMetrics.standard.typography.callout).fixedSize())
            .sizeThatFits(in: CGSize(width: 10_000, height: 100)).width
        for width in [1000.0, 1280, 1700] {
            let layout = layOut(split(.working(label, progress: 0.42)), size: CGSize(width: width, height: 800), compact: true)
            // Hosted items: leading groups, status, panels. The status is the middle one when there are three.
            guard layout.items.count >= 3 else { XCTFail("\(Int(width)): \(layout.items.count) toolbar items"); continue }
            let status = layout.items[1]
            guard status.visible, status.frame.width > 1 else { continue }   // hidden: fine
            XCTAssertGreaterThanOrEqual(status.frame.width, needed + LumenMetrics.standard.iconSize.regular,
                                        "\(Int(width)) pt window: the status shows in \(Int(status.frame.width)) pt; its label alone needs \(Int(needed.rounded(.up)))")
        }
    }

    /// The other side of the same rule: with room to spare, a short status shows, whole. (The
    /// truncation test above passes when the capsule hides, so on its own it can't tell a working
    /// status from one that never appears.)
    func testTopBarStatusShowsWhenThereIsRoom() throws {
        let label = "Indexing"
        let needed = NSHostingController(rootView: Text(label).font(LumenMetrics.standard.typography.callout).fixedSize())
            .sizeThatFits(in: CGSize(width: 10_000, height: 100)).width
        let layout = layOut(split(.working(label, progress: 0.42)), size: CGSize(width: 1700, height: 800), compact: true)
        XCTAssertGreaterThanOrEqual(layout.items.count, 3, "\(layout.items.count) toolbar items")
        let status = try XCTUnwrap(layout.items.count >= 3 ? layout.items[1] : nil)
        XCTAssertTrue(status.visible && status.frame.width > 1, "a short status is hidden in a 1700 pt window (\(status.frame))")
        XCTAssertGreaterThanOrEqual(status.frame.width, needed + LumenMetrics.standard.iconSize.regular,
                                    "the status shows in \(Int(status.frame.width)) pt; its label alone needs \(Int(needed.rounded(.up)))")
    }

    /// Every top-bar item sits on the window buttons' center line, past the buttons.
    func testTopBarItemsSitOnTheWindowButtonsCenterLine() throws {
        for size in [CGSize(width: SplitLayout.windowMinWidth, height: 700), CGSize(width: 1280, height: 800)] {
            let layout = layOut(split(), size: size, compact: true)
            let buttons = try XCTUnwrap(layout.buttons)
            XCTAssertFalse(layout.items.isEmpty, "no toolbar items at \(size)")
            for (index, item) in layout.items.enumerated() where item.visible && item.frame.width > 1 {
                XCTAssertEqual(item.frame.midY, buttons.midY, accuracy: 1, "\(Int(size.width)): item \(index + 1) is off the buttons' center line")
                XCTAssertGreaterThanOrEqual(item.frame.minX, buttons.maxX - 0.5, "\(Int(size.width)): item \(index + 1) overlaps the window buttons")
            }
        }
    }
}

/// What the window's views report, collected while it lays out.
@MainActor
private final class LiveLayoutBox { var bar: CGRect?; var top: CGFloat? }

/// The split workspace's top bar over plain panes, with a given activity.
private struct SplitStatusHarness: View {
    var activity: LumenActivity
    var body: some View {
        HSplitView {
            LumenSourceList([LumenSourceListItem(id: "main", title: "main", systemImage: "lumen.entryPoint")], selection: .constant("main"))
                .lumenSidebarColumn()
            Color.clear.lumenColumn(min: SplitLayout.editorMinWidth)
            LumenInspectorPane { LumenInspectorHeader("main", subtitle: "Function", systemImage: "lumen.pseudocode", hue: .hueIndigo) }
        }
        .lumenTopBar {
            SplitWorkspaceTopBar(showsNavigator: .constant(true), showsDebugger: .constant(false), showsInspector: .constant(true),
                                 activity: .constant(activity))
        }
    }
}

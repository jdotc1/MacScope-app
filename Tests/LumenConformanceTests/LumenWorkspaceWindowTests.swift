import XCTest
import SwiftUI
import LumenTokens
import LumenUI
import LumenConformance

@MainActor final class LumenWorkspaceWindowTests: XCTestCase {
    private func window(_ panels: LumenWorkspacePanels) -> some View {
        LumenWorkspaceWindow(panels: .constant(panels)) {
            // Content far taller than any window: it must be clipped, never move the bar.
            VStack { ForEach(0..<200) { Text("row \($0)") } }
        } sidebar: {
            Color.red.frame(minHeight: 2000)
        } inspector: {
            Color.blue.frame(minHeight: 3000)
        } bottom: {
            Color.green.frame(minHeight: 1500)
        } topLeading: {
            Text("Project")
        } topCenter: {
            Text("Untitled Workspace")
        }
    }

    func testTheTopBarStaysPutForEveryPanelCombination() {
        XCTAssertEqual(LumenConformance.workspaceWindow(window: window).map(\.description), [])
    }

    func testAHiddenSidebarReportsNoBacklightFindings() {
        let findings = LumenConformance.workspaceWindow(
            panels: LumenWorkspacePanels.allCombinations.filter { !$0.leading }
        ) { panels in
            LumenWorkspaceWindow(panels: .constant(panels)) {
                Color.clear
            } sidebar: {
                VStack(spacing: 0) {
                    LumenSidebarSwitcher(selection: .constant("project"), items: [
                        LumenSidebarItem(id: "project", title: "Project", systemImage: "square.stack.3d.up", hue: .huePink),
                        LumenSidebarItem(id: "functions", title: "Functions", systemImage: "function", hue: .hueBlue),
                        LumenSidebarItem(id: "strings", title: "Strings", systemImage: "text.quote", hue: .hueOrange),
                    ], shortcuts: false, style: .tiles)
                    Color.clear
                }
            } inspector: {
                Color.blue
            } bottom: {
                Color.green
            } topLeading: {
                Text("Project")
            }
        }
        XCTAssertEqual(findings.filter { $0.message.contains("backlight") }.map(\.description), [])
    }

    func testTheTopBarModifierIsPinnedToo() {
        let findings = LumenConformance.workspaceWindow(panels: [LumenWorkspacePanels()]) { _ in
            VStack { ForEach(0..<200) { Text("row \($0)") } }
                .lumenTopBar { LumenTopBar { Text("Leading") } trailing: { Text("Trailing") } }
        }
        XCTAssertEqual(findings.map(\.description), [])
    }

    // MARK: Placements

    func testTheOldPlacementStillHoldsForEveryPanelCombination() {
        let findings = LumenConformance.workspaceWindow(sizes: [CGSize(width: 900, height: 560)]) { panels in
            window(panels).lumenTopBarPlacement(.underTitleBar)
        }
        XCTAssertEqual(findings.map(\.description), [])
    }

    func testTheTopBarModifierHonorsTheOldPlacement() {
        let findings = LumenConformance.workspaceWindow(panels: [LumenWorkspacePanels()]) { _ in
            VStack { ForEach(0..<200) { Text("row \($0)") } }
                .lumenTopBar { LumenTopBar { Text("Leading") } trailing: { Text("Trailing") } }
                .lumenTopBarPlacement(.underTitleBar)
        }
        XCTAssertEqual(findings.map(\.description), [])
    }

    /// The three-pane arrangement as toolbar items: the window's real toolbar in the compact style hosts them,
    /// every item on the window buttons' center line (±1 pt), none under the buttons, the content
    /// under the band. (The check reads the items' frames from the window's toolbar.)
    func testThreePaneArrangementFitsTheUnifiedBar() {
        let tasks = [LumenTaskAction("Analyze", systemImage: "hammer.fill", hue: .hueOrange) {},
                     LumenTaskAction("Launch", systemImage: "play.fill", role: .start) {},
                     LumenTaskAction("Stop", systemImage: "stop.fill", role: .stop) {}]
        let activity = LumenActivity.working("Analyzing libsystem_kernel.dylib", progress: 0.42)
        let findings = LumenConformance.workspaceWindow(sizes: [CGSize(width: 1100, height: 600)], panels: [LumenWorkspacePanels()]) { panels in
            LumenWorkspaceWindow(panels: .constant(panels)) {
                VStack(spacing: 0) {
                    LumenContentTabBar {
                        LumenModeSwitcher(selection: .constant("Disassembly"), options: ["Disassembly", "Pseudocode", "Graph", "Hex"],
                                          style: .underline, title: { $0 })
                    }
                    Color.clear
                }
            } sidebar: {
                Color.red
            } inspector: {
                Color.blue
            } topLeading: {
                LumenWorkspaceToolbar {
                    LumenIconTile("scope", hue: .huePink, size: 22).lumenTileBacklight()
                } project: {
                    LumenToolbarIdentity("vim", subtitle: "arm64e · Mach-O executable", systemImage: "doc.fill", hue: .hueOrange)
                } tasks: {
                    LumenTaskCluster(tasks, activity: activity)
                }
            } topCenter: {
                LumenToolbarStatus(activity)
            }
            .newItemButton {}
        }
        XCTAssertEqual(findings.map(\.description), [])
    }

    /// The Split Workspace's bar at its 900 pt minimum: a long binary name, the slice pop-up and a
    /// 300 pt status pill must still leave room for the panel toggles and New Tab (they were dropped
    /// from the toolbar, not even in its overflow menu).
    func testThePanelsSurviveTheMinimumWidth() {
        let tasks = [LumenTaskAction("Analyze", systemImage: "hammer.fill", hue: .hueOrange) {},
                     LumenTaskAction("Launch", systemImage: "play.fill", role: .start) {},
                     LumenTaskAction("Stop", systemImage: "stop.fill", role: .stop) {}]
        let activity = LumenActivity.working("Analyzing libsystem_kernel.dylib", progress: 0.42)
        let findings = LumenConformance.workspaceWindow(sizes: [CGSize(width: 900, height: 600)], panels: [LumenWorkspacePanels()]) { panels in
            LumenWorkspaceWindow(panels: .constant(panels)) {
                Color.clear
            } sidebar: {
                Color.red
            } inspector: {
                Color.blue
            } bottom: {
                Color.green
            } topLeading: {
                LumenWorkspaceToolbar {
                    LumenIconTile("scope", hue: .huePink, size: 20).lumenTileBacklight()
                } project: {
                    LumenToolbarIdentity("libsystem_kernel.dylib", subtitle: "arm64e · Mach-O dylib", systemImage: "doc.fill", hue: .hueOrange)
                } tasks: {
                    LumenTaskCluster(tasks, activity: activity)
                } configuration: {
                    LumenPopUp(selection: .constant("arm64e"), options: ["arm64e", "arm64", "x86_64"], title: { $0 })
                }
            } topCenter: {
                LumenToolbarStatus(activity, width: 300)
            }
            .newItemButton {}
        }
        XCTAssertEqual(findings.map(\.description), [])
    }

    /// The live failure, rebuilt: one window shrunk from 1250 to 900 pt in steps. AppKit dropped the
    /// trailing panels mid-resize (before the status reacted) and never brought them back. The bar is
    /// now one flexible toolbar item, so at every step that item is visible, spans the toolbar, and
    /// holds the panel toggles.
    func testShrinkingTheWindowNeverDropsThePanels() throws {
        let tasks = [LumenTaskAction("Analyze", systemImage: "hammer.fill", hue: .hueOrange) {},
                     LumenTaskAction("Launch", systemImage: "play.fill", role: .start) {},
                     LumenTaskAction("Stop", systemImage: "stop.fill", role: .stop) {}]
        let activity = LumenActivity.working("Analyzing libsystem_kernel.dylib", progress: 0.42)
        let root = LumenWorkspaceWindow(panels: .constant(LumenWorkspacePanels())) {
            Color.clear
        } sidebar: {
            Color.red
        } inspector: {
            Color.blue
        } bottom: {
            Color.green
        } topLeading: {
            LumenWorkspaceToolbar {
                LumenIconTile("scope", hue: .huePink, size: 20).lumenTileBacklight()
            } project: {
                LumenToolbarIdentity("libsystem_kernel.dylib", subtitle: "arm64e · Mach-O dylib", systemImage: "doc.fill", hue: .hueOrange)
            } tasks: {
                LumenTaskCluster(tasks, activity: activity)
            } configuration: {
                LumenPopUp(selection: .constant("arm64e"), options: ["arm64e", "arm64", "x86_64"], title: { $0 })
            }
        } topCenter: {
            LumenToolbarStatus(activity, width: 300)
        }
        .newItemButton {}
        let host = NSHostingView(rootView: root.lumenPaletteRoot())
        host.sizingOptions = []
        host.sceneBridgingOptions = [.toolbars]
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1250, height: 640),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.toolbarStyle = .unifiedCompact
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        func settle() {
            for _ in 0..<3 {
                // The whole window, title bar and toolbar included, as a live window lays out.
                (host.superview ?? host).layoutSubtreeIfNeeded()
                RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            }
        }
        settle()
        for width in stride(from: 1250, through: 900, by: -50) {
            window.setContentSize(CGSize(width: CGFloat(width), height: 640))
            settle()
            let toolbar = try XCTUnwrap(window.toolbar, "\(width) pt: no toolbar")
            let hosted = toolbar.items.filter { $0.view != nil }
            XCTAssertEqual(hosted.count, 3, "\(width) pt: leading, status and panels items")
            // The backstop: if a resize ever outruns the status's budget, AppKit gives up the status.
            XCTAssertEqual(hosted[1].visibilityPriority, .low, "\(width) pt: the status isn't the first to go")
            XCTAssertEqual(hosted[2].visibilityPriority, .high, "\(width) pt: the panels aren't kept first")
            let visible = toolbar.visibleItems ?? []
            // The panels (the last item) and the leading content stay; only the status may go.
            let panels = try XCTUnwrap(hosted.last)
            XCTAssertTrue(visible.contains(panels), "\(width) pt: the panels item was dropped")
            XCTAssertTrue(visible.contains(hosted[0]), "\(width) pt: the leading item was dropped")
            let view = try XCTUnwrap(panels.view)
            XCTAssertNotNil(view.window, "\(width) pt: the panels aren't in the window")
            let frame = view.convert(view.bounds, to: nil)
            XCTAssertGreaterThan(frame.maxX, CGFloat(width) - 24, "\(width) pt: the panels aren't at the trailing edge (\(frame))")
            // Three toggles and New Tab (the offscreen window builds no accessibility tree to name them).
            XCTAssertGreaterThan(frame.width, 120, "\(width) pt: the panels item lost its toggles (\(frame))")
        }
    }

    /// A bar in the title bar band whose content starts at the window's edge, under the buttons.
    func testContentUnderTheWindowButtonsIsReported() {
        let findings = LumenConformance.workspaceWindow(panels: [LumenWorkspacePanels()]) { _ in
            VStack(spacing: 0) {
                HStack {
                    Text("Project")
                        .background { GeometryReader { Color.clear.preference(key: LumenTopBarContentFrameKey.self, value: $0.frame(in: .global)) } }
                    Spacer()
                }
                .padding(.horizontal, 8)
                .frame(height: LumenLayout.unifiedTopBarHeight)
                .background { GeometryReader { Color.clear.preference(key: LumenTopBarFrameKey.self, value: $0.frame(in: .global)) } }
                Color.gray
            }
            .ignoresSafeArea(.container, edges: .top)
            .preference(key: LumenTopBarPlacementKey.self, value: .unified)
        }
        XCTAssertTrue(findings.contains { $0.message == "toolbar content overlaps the window buttons" }, findings.map(\.description).joined(separator: "\n"))
        // Hand-drawn in the band instead of hosted in the toolbar: nothing puts it on the buttons' line.
        XCTAssertTrue(findings.contains { $0.message == "the unified top bar has no window toolbar to host its items" })
    }

    /// Split-view content right under a bar that's exactly the band's height: SwiftUI stretches the
    /// AppKit split view up into the band, under the bar. The unified placement keeps a hairline row
    /// between them for this; a hand-built bar without it must be reported.
    func testSplitContentStretchedUnderTheBandIsReported() {
        let findings = LumenConformance.workspaceWindow(panels: [LumenWorkspacePanels()]) { _ in
            VStack(spacing: 0) {
                Color.clear
                    .frame(height: 32)   // the plain hidden title bar's band in the test window
                    .background { GeometryReader { Color.clear.preference(key: LumenTopBarFrameKey.self, value: $0.frame(in: .global)) } }
                HSplitView {
                    Color.gray.background { GeometryReader { Color.clear.preference(key: LumenRegionTopKey.self, value: $0.frame(in: .global).minY) } }
                    Color.blue
                }
            }
            .ignoresSafeArea(.container, edges: .top)
            .preference(key: LumenTopBarPlacementKey.self, value: .unified)
        }
        XCTAssertTrue(findings.contains { $0.message.hasPrefix("a panel starts") }, findings.map(\.description).joined(separator: "\n"))
    }

    /// A bar that claims the unified placement but sits under the band, as the old one did.
    func testAUnifiedBarUnderTheBandIsReported() {
        let findings = LumenConformance.workspaceWindow(panels: [LumenWorkspacePanels()]) { _ in
            VStack(spacing: 0) {
                LumenTopBar { Text("Leading") } trailing: { Text("Trailing") }
                    .background { GeometryReader { Color.clear.preference(key: LumenTopBarFrameKey.self, value: $0.frame(in: .global)) } }
                Color.gray
            }
            .preference(key: LumenTopBarPlacementKey.self, value: .unified)
        }
        XCTAssertTrue(findings.contains { $0.message.hasPrefix("top bar starts") && $0.message.hasSuffix("below the window's top") },
                      findings.map(\.description).joined(separator: "\n"))
    }

    func testAWindowWithoutLumensBarIsReported() {
        let findings = LumenConformance.workspaceWindow(panels: [LumenWorkspacePanels()]) { _ in
            VStack(spacing: 0) { Text("My own bar"); Color.gray }
        }
        XCTAssertEqual(findings.count, 2)
        XCTAssertTrue(findings.allSatisfy { $0.message.contains("no Lumen top bar") })
    }

    func testAllCombinationsCoverEightStates() {
        XCTAssertEqual(Set(LumenWorkspacePanels.allCombinations).count, 8)
    }

    /// MacScope's bug, rebuilt: a bar stacked over content taller than the window. The check must
    /// see the bar pushed off the top.
    func testTheCheckCatchesABarPushedOffScreen() {
        let findings = LumenConformance.workspaceWindow(panels: [LumenWorkspacePanels()]) { _ in
            VStack(spacing: 0) {
                LumenTopBar { Text("Leading") } trailing: { Text("Trailing") }
                    .background {
                        GeometryReader { proxy in
                            Color.clear.preference(key: LumenTopBarFrameKey.self, value: proxy.frame(in: .global))
                        }
                    }
                Color.gray.frame(minHeight: 3000)
            }
        }
        XCTAssertFalse(findings.isEmpty, "a stacked bar over oversized content must be reported")
        XCTAssertTrue(findings.allSatisfy { $0.message.contains("moved") }, findings.map(\.description).joined(separator: "\n"))
    }

    func testAnEmbeddedBottomPanelKeepsTheBarPinned() {
        let findings = LumenConformance.workspaceWindow { panels in
            LumenWorkspaceWindow(panels: .constant(panels)) {
                VStack(spacing: 0) {
                    VStack { ForEach(0..<200) { Text("row \($0)") } }
                    if panels.bottom { Color.green.frame(height: 240) }
                }
            } sidebar: {
                Color.red
            } inspector: {
                Color.blue
            } topLeading: {
                Text("Project")
            }
            .bottomPanelToggle(.constant(panels.bottom))
        }
        XCTAssertEqual(findings.map(\.description), [])
    }

    func testATruncatedTitleIsReported() {
        let findings = LumenConformance.truncation(sizes: [CGSize(width: 400, height: 200)]) {
            Text("Untitled Workspace").lineLimit(1).lumenNeverTruncates("Untitled Workspace").frame(width: 60)
        }
        XCTAssertEqual(findings.map(\.description), ["layout · 400×200: “Untitled Workspace” is cut short"])
    }

    func testALabelThatFitsIsNotReported() {
        let findings = LumenConformance.truncation(sizes: [CGSize(width: 400, height: 200)]) {
            Text("Untitled Workspace").lineLimit(1).lumenNeverTruncates("Untitled Workspace")
        }
        XCTAssertEqual(findings, [])
    }

    func testABreadcrumbSqueezedLikeMacScopesIsReported() {
        let findings = LumenConformance.truncation(sizes: [CGSize(width: 900, height: 200)]) {
            LumenToolbarBreadcrumb(["Untitled Workspace"], systemImage: "cpu").frame(width: 120, alignment: .leading)
        }
        XCTAssertFalse(findings.isEmpty)
    }

    func testRuleEditorOperatorsAreNeverCutShort() {
        let conditions = [LumenRuleCondition(field: "Name", comparison: "doesn't contain", value: "objc"),
                          LumenRuleCondition(field: "Address", comparison: "greater than", value: "0x1000")]
        let findings = LumenConformance.truncation(sizes: [CGSize(width: 520, height: 260)]) {
            LumenRuleEditor(match: .constant(.all), conditions: .constant(conditions), fields: ["Name", "Kind", "Library", "Address"],
                            comparisons: { $0 == "Address" ? ["is", "greater than", "less than"]
                                                          : ["contains", "is", "begins with", "ends with", "doesn't contain"] })
                .padding()
        }
        XCTAssertEqual(findings.map(\.description), [])
    }
}

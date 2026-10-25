import SwiftUI
import LumenTokens
import LumenUI

// Workspace layout pieces: split editors, stacked sidebars and the sidebar pane grid, live.

struct WorkspacePage: View {
    @State private var layout = WorkspacePage.twoPanes
    @State private var collapsed: Set<String> = ["str"]
    @State private var arrangement = "files,find,-symbols,git"
    @State private var indexing = true

    private static let twoPanes = LumenEditorLayout(panes: [
        LumenEditorPane(id: "L", tabs: [
            LumenDocumentTab(id: "pkg", title: "Package.swift", systemImage: "shippingbox", hue: .hueOrange, isPinned: true),
            LumenDocumentTab(id: "listing", title: "Listing.swift", systemImage: "swift", hue: .hueOrange, isEdited: true),
        ], selection: "listing"),
        LumenEditorPane(id: "R", tabs: [
            LumenDocumentTab(id: "zsh", title: "zsh", systemImage: "terminal", hue: .hueTeal, isPinned: false, accent: .hueTeal),
        ]),
    ], focusedPaneID: "L")

    private static let panes = [
        LumenSidebarItem(id: "files", title: "Files", systemImage: "folder", hue: .hueBlue),
        LumenSidebarItem(id: "find", title: "Find", systemImage: "magnifyingglass", hue: .hueOrange),
        LumenSidebarItem(id: "symbols", title: "Symbols", systemImage: "list.bullet.indent", hue: .huePink),
        LumenSidebarItem(id: "git", title: "Git", systemImage: "arrow.triangle.branch", hue: .hueGreen),
    ]

    /// The identity and the task cluster, the bar's fixed groups.
    private var toolbarGroups: some View {
        HStack(spacing: 8) {
            LumenToolbarIdentity("Lumen", subtitle: "main", systemImage: "lumen.lens", hue: .hueViolet)
            LumenToolbarDivider()
            LumenTaskCluster([LumenTaskAction("Build", systemImage: "hammer.fill", hue: .hueOrange) {},
                              LumenTaskAction("Run", systemImage: "play.fill", role: .start) {},
                              LumenTaskAction("Stop", systemImage: "stop.fill", role: .stop) {}],
                             activity: indexing ? .working("Indexing") : .idle())
        }
        .fixedSize()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PageHeader(title: "Workspace", summary: "Split editors with a tab bar per pane, stacked sidebar panes that collapse and share their height, the sidebar pane grid, the breadcrumb’s live activity and a floating status.")

            LumenSectionHeader("Split editor")
            HStack(spacing: 10) {
                Button("Split", systemImage: "rectangle.split.2x1") { layout = Self.twoPanes }.disabled(layout.panes.count > 1)
                Button("Single Pane", systemImage: "rectangle") {
                    layout = LumenEditorLayout(panes: [layout.panes[0]], focusedPaneID: layout.panes[0].id)
                }
                .disabled(layout.panes.count < 2)
                Text("Drag a tab between panes, or the divider to resize.").font(.caption).foregroundStyle(.lumen(.fgTertiary))
            }
            LumenSplitEditor(layout: $layout, minimumPaneWidth: 160) { pane in
                WorkspaceEditorStandIn(title: pane.tabs.first { $0.id == pane.selection }?.title ?? "No document")
            }
            .frame(maxWidth: 420).frame(height: 170)
            .lumenFloatingStatus {
                Text("Ln 12, Col 4"); Text("Swift"); Text("UTF-8"); Text("Spaces: 4")
            } folded: {
                Text("Ln 12, Col 4"); Text("Swift")
            }
            .clipShape(.rect(cornerRadius: 8))
            .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(.lumen(.borderSubtle)) }

            LumenSectionHeader("Stacked sidebar")
            LumenStackedSidebar([
                LumenStackedPane(id: "fn", title: "Functions", systemImage: "function", hue: .huePink, count: 3,
                                 actions: [LumenBarAction("Add", systemImage: "plus") {}]) {
                    VStack(alignment: .leading, spacing: 3) { Text("main"); Text("parse_header"); Text("compute(_:)") }
                        .font(.caption).padding(.leading, 34)
                },
                LumenStackedPane(id: "bp", title: "Breakpoints", systemImage: "lumen.breakpoint", hue: .hueBlue, count: 0,
                                 emptyMessage: "Click a line number to add one.") { EmptyView() },
                LumenStackedPane(id: "str", title: "Strings", systemImage: "text.quote", hue: .hueOrange, count: 1284) {
                    VStack(alignment: .leading, spacing: 3) { Text("Hello, MacScope!"); Text("/usr/lib/libSystem.B.dylib") }
                        .font(.caption.monospaced()).padding(.leading, 34)
                },
            ], collapsed: $collapsed)
            .frame(width: 240, height: 260)
            .lumenSidebarBackground()
            .clipShape(.rect(cornerRadius: 8))

            LumenSectionHeader("Sidebar pane grid")
            LumenSidebarPaneGrid(Self.panes, arrangement: $arrangement)
                .frame(width: 260).lumenSidebarBackground().clipShape(.rect(cornerRadius: 8))
            Text("Arrangement: \(arrangement)").font(.caption.monospaced()).foregroundStyle(.lumen(.fgTertiary))

            LumenSectionHeader("Toolbar groups")
            Text("The Split Workspace window shows the whole layout: one unified bar with the window buttons inside it, and the editor modes in the content’s tab bar.")
                .font(.caption).foregroundStyle(.lumen(.fgTertiary))
            // One row when it fits; in a narrow page the status wraps to its own line without the
            // slash, which only ever goes between groups on one row.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    toolbarGroups
                    LumenToolbarStatus(indexing ? .working("Indexing… 16 of 92", progress: 0.17) : nil, width: 220).fixedSize()
                }
                VStack(alignment: .leading, spacing: 8) {
                    toolbarGroups
                    if indexing { LumenActivityStatus(.working("Indexing… 16 of 92", progress: 0.17), width: 220) }
                }
            }
            .padding(12)
            .frame(maxWidth: 420, alignment: .leading)
            .background(LumenTitlebarBackground())
            .clipShape(.rect(cornerRadius: 8))

            LumenSectionHeader("Breadcrumb with activity")
            HStack(spacing: 12) {
                LumenToolbarBreadcrumb(["Lumen", "main"], systemImage: "lumen.lens", hue: .hueViolet,
                                       activity: indexing ? .working("Indexing Files… 16 of 92", progress: 0.17) : nil) { indexing = false }
                if !indexing { Button("Index Again") { indexing = true } }
            }
        }
    }
}

/// A stand-in editor: the selected tab's name over lines of fake code.
private struct WorkspaceEditorStandIn: View {
    let title: String
    @Environment(\.lumenPalette) private var palette
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 11, design: .monospaced)).foregroundStyle(palette[.fgPrimary])
            ForEach([120, 80, 150, 60, 100], id: \.self) { width in
                RoundedRectangle(cornerRadius: 2).fill(palette[.fgTertiary].opacity(0.5)).frame(width: CGFloat(width), height: 6)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(palette[.bgCanvas])
    }
}

// Scene-scoped so a main Catalog window retains its New Window command.
private struct CatalogNewDocumentKey: FocusedValueKey {
    typealias Value = () -> Void
}

extension FocusedValues {
    var catalogNewDocument: (() -> Void)? {
        get { self[CatalogNewDocumentKey.self] }
        set { self[CatalogNewDocumentKey.self] = newValue }
    }
}

/// Value state owned by the Workspace window; numbering is never reused after closing a tab.
struct WorkspaceDemoModel {
    private(set) var tabs = [
        LumenDocumentTab(id: "index", title: "index.html", systemImage: "globe", hue: .hueGreen, isEdited: true),
        LumenDocumentTab(id: "style", title: "style.css", systemImage: "paintbrush.fill", hue: .huePink),
        LumenDocumentTab(id: "untitled", title: "untitled", systemImage: "doc", hue: .fgTertiary, isPreview: true),
    ]
    var selection: String? = "index"
    private var nextDocument = 2

    mutating func newDocument() {
        let id = "untitled-\(nextDocument)"
        tabs.append(LumenDocumentTab(id: id, title: "untitled \(nextDocument)", systemImage: "doc", hue: .fgTertiary))
        nextDocument += 1
        selection = id
    }

    mutating func close(_ id: String) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs.remove(at: index)
        if selection == id {
            selection = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)].id
        }
    }
}

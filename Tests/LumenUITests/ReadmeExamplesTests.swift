import SwiftUI
import XCTest
import LumenTokens
@testable import LumenUI

/// Compiles the snippets in README.md, so the documented API can't drift from the real one.
@MainActor
final class ReadmeExamplesTests: XCTestCase {
    func testReadmeSnippetsCompileAndRender() throws {
        let registry = LumenRegistry(packs: [.core])
        let store = LumenThemeStore(
            registry: registry,
            configuration: LumenStoreConfiguration(appName: "ReadmeExample", themesDirectory: FileManager.default.temporaryDirectory
                .appending(path: "lumen-readme-\(UUID().uuidString)"), defaultThemeID: LumenThemes.standardID),
            persistsSelection: false
        )
        let content = VStack {
            Text("Signed").foregroundStyle(.lumen(.statusSuccess))
            LumenBadge("3 warnings", tone: .warning)
            LumenEmptyState(systemImage: "doc", title: "No documents", message: "Import a manuscript to begin.")
            LumenEmptyState("No matching documents", prominence: .inline)
        }
        .lumenPaletteRoot(store: store)
        .lumenMetrics(.standard)
        .lumenDensityRoot(store: store)
        _ = LumenThemeGallery(store: store)
        XCTAssertNotNil(ImageRenderer(content: content.frame(width: 320, height: 240)).cgImage)
    }

    /// The welcome window and toolbar snippet, as written in the README.
    func testWelcomeAndToolbarSnippetCompiles() {
        var showWelcome = true
        let recents = [LumenRecentItem(title: "Survey", detail: "~/Notes/Survey")]
        let path = "~/Notes", activity = LumenActivity.working("Syncing", progress: 0.5)
        let tasks = [LumenTaskAction("Sync", systemImage: "arrow.triangle.2.circlepath", role: .start) {}]
        func newNotebook() {}
        func open(_ item: LumenRecentItem) {}
        let welcome = LumenWelcomeView(appName: "Field Notes", version: "2.1", tagline: "Notes from the field, in order.",
                         markSymbol: "book.closed.fill", markHue: .hueOrange,
                         actions: [LumenWelcomeAction("New Notebook", systemImage: "plus", hue: .hueOrange,
                                                      shortcut: KeyboardShortcut("n"), isPrimary: true) { newNotebook() }],
                         recents: recents, showAtLaunch: Binding(get: { showWelcome }, set: { showWelcome = $0 })) { open($0) }
        let toolbar = HStack {
            LumenToolbarIdentity("Field Notes", subtitle: path, systemImage: "book.closed.fill", hue: .hueOrange)
            LumenActivityStatus(activity)
            LumenTaskCluster(tasks, activity: activity)
        }
        _ = (welcome, toolbar)
    }

    /// The inspector and popover snippet, as written in the README.
    func testInspectorAndPopoverSnippetCompiles() {
        var showsInspector = true, sharing = false, hue = LumenToken.hueOrange, pages = 12
        let view = Text("Notebook")
            .lumenInspector(isPresented: Binding(get: { showsInspector }, set: { showsInspector = $0 })) {
                LumenInspectorHeader("Survey", subtitle: "Notebook", systemImage: "book.closed.fill", hue: .hueOrange)
                LumenInspectorSection("Appearance", systemImage: "paintpalette.fill", hue: .huePink) {
                    LumenInspectorRow("Color") { LumenHuePickerButton(selection: Binding(get: { hue }, set: { hue = $0 })) }
                    LumenInspectorRow("Pages") { Stepper("Pages", value: Binding(get: { pages }, set: { pages = $0 })) }
                }
            }
        let info = LumenInfoButton("Sync", message: "Notebooks sync when the Mac is on power.")
        let share = Button("Share…") { sharing = true }
            .lumenPopover(isPresented: Binding(get: { sharing }, set: { sharing = $0 }), title: "Share Notebook", systemImage: "square.and.arrow.up.fill", hue: .hueBlue) {
                Text("Exports the notebook.")
            }
        _ = (view, info, share, LumenInspectorToggle(isPresented: .constant(true)))
    }

    /// The workspace snippet, as written in the README.
    func testWorkspaceSnippetCompiles() {
        var showsPanel = true, showsDock = false, showsSidebar = true, showsNew = false, tab = "console"
        var entries = [LumenLogEntry(date: .now, source: "Swift", message: "Ready")]
        let tabs = [LumenPanelTab(id: "console", title: "Console", systemImage: "terminal")]
        let newItems = [LumenLaunchItem("Document", systemImage: "doc.fill", hue: .hueGraphite) {}]
        let sidebar = Text("Sidebar"), editor = Text("Editor")
        let view = NavigationSplitView { sidebar } detail: {
            editor
                .lumenBottomPanel(isPresented: Binding(get: { showsPanel }, set: { showsPanel = $0 })) {
                    LumenPanelTabs(selection: Binding(get: { tab }, set: { tab = $0 }), tabs: tabs)
                    LumenLogConsole(entries) { entries = [] }
                }
                .inspector(isPresented: Binding(get: { showsDock }, set: { showsDock = $0 })) { LumenDropZone() }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) { LumenToolbarBreadcrumb(["Lumen"], systemImage: "lumen.lens", hue: .hueViolet) }
            ToolbarItem(placement: .primaryAction) {
                LumenPanelToggles(leading: Binding(get: { showsSidebar }, set: { showsSidebar = $0 }), bottom: Binding(get: { showsPanel }, set: { showsPanel = $0 }),
                                  trailing: Binding(get: { showsDock }, set: { showsDock = $0 }))
            }
            ToolbarItem(placement: .primaryAction) {
                LumenNewItemButton { showsNew = true }.lumenLaunchMenu(isPresented: Binding(get: { showsNew }, set: { showsNew = $0 }), items: newItems)
            }
        }
        .lumenWindowChrome()
        _ = view
    }

    /// The command palette snippet, as written in the README.
    func testCommandPaletteSnippetCompiles() {
        var showsPalette = false, showsPanel = true
        let content = Text("Workspace")
        let view = content
            .lumenCommandPalette(isPresented: Binding(get: { showsPalette }, set: { showsPalette = $0 }), commands: [
                LumenCommand("Hide Panel", category: "View", systemImage: "rectangle.bottomthird.inset.filled",
                             shortcut: LumenShortcuts.panel) { showsPanel.toggle() },
                LumenCommand("Go to Call Graph", category: "Go", systemImage: "lumen.callGraph", hue: .hueGreen,
                             keywords: ["functions", "callers"]) {},
            ])
        _ = view
    }

    /// The glyph snippet, as written in the README.
    func testGlyphSnippetCompiles() {
        let myAppGlyph = LumenGlyph(id: "readme.example", title: "Example", family: "README") { $0.fill.addEllipse(in: CGRect(x: 6, y: 6, width: 12, height: 12)) }
        let views = VStack {
            LumenIconTile(LumenGlyph.callGraph.symbolName, hue: .hueGreen, size: 28)
            LumenBadge("Anonymized", systemImage: "lumen.anonymize", tone: .success)
            LumenGlyphView(.breakpoint, size: 24).foregroundStyle(.lumen(.accent))
            Label { Text("Breakpoints") } icon: { LumenGlyph.breakpoint.image() }
        }
        LumenGlyph.register([myAppGlyph])
        XCTAssertNotNil(ImageRenderer(content: views).cgImage)
    }
}

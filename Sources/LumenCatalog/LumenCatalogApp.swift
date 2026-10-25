import AppKit
import SwiftUI
import MacScopeShell
import LumenTokens
import LumenUI

/// Lumen Catalog: every Lumen component in a real Mac app, including the parts that only render
/// natively (menus, settings windows, controls). Run with `swift run LumenCatalog`.
@main
struct LumenCatalogApp: App {
    @State private var store: LumenThemeStore

    init() {
        NSApplication.shared.setActivationPolicy(.regular)
        // `LUMEN_CATALOG_APPEARANCE=light|dark` overrides the system appearance (for screenshots).
        switch ProcessInfo.processInfo.environment["LUMEN_CATALOG_APPEARANCE"] {
        case "light": NSApplication.shared.appearance = NSAppearance(named: .aqua)
        case "dark": NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        default: break
        }
        let isPreview = Bundle.main.object(forInfoDictionaryKey: "LumenCatalogPreview") as? Bool == true
        let previewData = Bundle.main.object(forInfoDictionaryKey: "LumenCatalogPreviewDataDirectory") as? String
        let store = LumenThemeStore(
            // The code pack colors the listing, pseudocode, strings and hex demos.
            registry: LumenRegistry(packs: [.core, .code]),
            // Saved in a suite of its own, so the Appearance settings demo (density, accent) works.
            configuration: LumenStoreConfiguration(
                appName: isPreview ? "LumenCatalogSemanticPreview" : "LumenCatalog",
                themesDirectory: isPreview
                    ? URL(fileURLWithPath: previewData ?? NSHomeDirectory() + "/LumenPreview/Data").appending(path: "Themes")
                    : FileManager.default.temporaryDirectory.appending(path: "LumenCatalogThemes"),
                defaultsSuiteName: isPreview ? "com.lumen.catalog.semantic-preview" : "com.lumen.catalog.demo")
        )
        LumenThemeStore.install(store, watchesThemesFolder: false)
        // `LUMEN_CATALOG_THEME=lumen.ultraviolet` picks a theme (for screenshots).
        if let theme = ProcessInfo.processInfo.environment["LUMEN_CATALOG_THEME"] { store.select(theme) }
        LumenGlyph.register([.catalogPage])
        _store = State(initialValue: store)
    }

    var body: some Scene {
        WindowGroup(Bundle.main.object(forInfoDictionaryKey: "LumenCatalogPreview") as? Bool == true
                    ? "Lumen Semantic Text Preview" : "Lumen Catalog", id: "catalog") {
            CatalogView()
                .lumenPaletteRoot(store: store)
                .lumenDensityRoot(store: store)
                .lumenMetrics(.standard)
                .modifier(CatalogWindowMinimum())
                .onAppear {
                    NSApplication.shared.activate(ignoringOtherApps: true)
                    LumenDockIcon.apply("lumen.lens", hue: .hueViolet)   // the Catalog has no icon asset
                }
        }
        .commands {
            CatalogCommands()
            LumenViewCommands()   // View › Show/Hide Navigator, Panel, Inspector; Window › Previous/Next Tab
        }

        // The workspace window: a three-pane layout built from Lumen's workspace pieces.
        Window("Workspace", id: "workspace") {
            WorkspaceDemo()
                .lumenPaletteRoot(store: store)
                .lumenDensityRoot(store: store)
                .lumenMetrics(.standard)
                .frame(minWidth: 1000, minHeight: 660)
        }

        // MacScope's structure: a hidden title bar with the app's own top bar and HSplitView columns,
        // built from Lumen's split-layout pieces. Every Lumen release is exercised here.
        Window("Split Workspace", id: "split") {
            SplitWorkspaceDemo()
                .lumenPaletteRoot(store: store)
                .lumenDensityRoot(store: store)
                .lumenMetrics(.standard)
        }
        .windowStyle(.hiddenTitleBar)
        // A compact band: the top bar's items sit on the window buttons' center line.
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))

        Window("MacScope workspace", id: "macscope-workspace") {
            MacScopeWorkspace()
                .lumenPaletteRoot(store: store)
                .lumenDensityRoot(store: store)
                .lumenMetrics(.standard)
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))
        .defaultSize(width: MacScopeWorkspace.defaultSize.width, height: MacScopeWorkspace.defaultSize.height)

        // The welcome window: hidden title bar, sized to its content, centered.
        Window("Welcome to Lumen", id: "welcome") {
            CatalogWelcome()
                .lumenPaletteRoot(store: store)
                .lumenDensityRoot(store: store)
                .lumenMetrics(.standard)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        Settings {
            CatalogSettings()
                .lumenPaletteRoot(store: store)
                .lumenDensityRoot(store: store)
                .frame(width: 620, height: 460)
        }
    }
}

// MARK: Native menus

/// A real menu-bar menu: native highlighting, keyboard navigation, submenus and shortcuts, plus
/// Lumen's colored tiles.
struct CatalogCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.catalogNewDocument) private var newDocument

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button(newDocument == nil ? "New Window" : "New Document") {
                if let newDocument { newDocument() } else { openWindow(id: "catalog") }
            }
            .keyboardShortcut("n")
        }
        CommandMenu("Lumen") {
            Button("MacScope workspace") { openWindow(id: "macscope-workspace") }
            Divider()
            Button {} label: { LumenMenuLabel("Go to Address…", systemImage: "number", hue: .hueBlue) }
                .keyboardShortcut("g")
            Button {} label: { LumenMenuLabel("Find in Project", systemImage: "magnifyingglass", hue: .hueTeal) }
                .keyboardShortcut("f", modifiers: [.command, .shift])
            Menu {
                Button {} label: { LumenMenuLabel("Calculator.app", systemImage: "app.fill", hue: .hueGraphite) }
                Button {} label: { LumenMenuLabel("libsystem_kernel.dylib", systemImage: "shippingbox.fill", hue: .hueIndigo) }
                Divider()
                Button("Clear Menu") {}
            } label: {
                LumenMenuLabel("Open Recent", systemImage: "clock.fill", hue: .hueOrange)
            }
            Divider()
            // No shortcut: ⌥⌘I belongs to View › Show Inspector (LumenViewCommands), one owner per shortcut.
            Button {} label: { LumenMenuLabel("Show Inspector", systemImage: "sidebar.right", hue: .hueViolet) }
            Button(role: .destructive) {} label: { LumenMenuLabel("Delete Bookmark", systemImage: "trash.fill", hue: .hueRed) }
        }
    }
}

// MARK: Catalog window

enum CatalogPage: String, CaseIterable, Identifiable {
    case overview = "Overview", welcome = "Welcome", toolbar = "Toolbar", tiles = "Icon Tiles", menus = "Menus",
         settings = "Settings", popovers = "Popovers", glyphs = "Glyphs", components = "Components",
         forms = "Forms & Controls", search = "Search & Navigation", data = "Data & Git", browse = "Browse", workspace = "Workspace",
         states = "States & Rows", debugger = "Debugger", editor = "Editor", sheets = "Sheets & Settings", themes = "Themes"
    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .overview: "sparkles"
        case .welcome: "hand.wave.fill"
        case .toolbar: "menubar.rectangle"
        case .tiles: "square.grid.3x3.fill"
        case .menus: "filemenu.and.selection"
        case .settings: "gearshape.fill"
        case .components: "puzzlepiece.fill"
        case .forms: "slider.horizontal.3"
        case .search: "magnifyingglass"
        case .data: "arrow.triangle.branch"
        case .browse: "square.grid.2x2.fill"
        case .workspace: "rectangle.split.3x1.fill"
        case .themes: "paintpalette.fill"
        case .popovers: "text.bubble.fill"
        case .glyphs: "lumen.lens"
        case .states: "list.bullet.rectangle.fill"
        case .debugger: "ladybug.fill"
        case .editor: "chevron.left.forwardslash.chevron.right"
        case .sheets: "rectangle.on.rectangle"
        }
    }

    var hue: LumenToken {
        switch self {
        case .overview: .hueViolet
        case .welcome: .hueYellow
        case .toolbar: .hueIndigo
        case .tiles: .huePink
        case .menus: .hueBlue
        case .settings: .hueGraphite
        case .components: .hueGreen
        case .forms: .hueBlue
        case .search: .hueOrange
        case .data: .hueTeal
        case .browse: .hueYellow
        case .workspace: .hueViolet
        case .themes: .hueOrange
        case .popovers: .hueTeal
        case .glyphs: .hueIndigo
        case .states: .hueRed
        case .debugger: .hueRed
        case .editor: .huePink
        case .sheets: .hueTeal
        }
    }
}

struct CatalogView: View {
    private let forceLegacyColumns: Bool

    init(useLegacyColumns: Bool = false) {
        forceLegacyColumns = useLegacyColumns
    }

    private var usesLegacyColumns: Bool {
        if #available(macOS 27, *) { return forceLegacyColumns }
        return true
    }

    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    @State private var activity: LumenActivity = .idle()
    @State private var job: Task<Void, Never>?
    @State private var showsPalette = false
    @State private var showsSidebar = true
    /// `LUMEN_CATALOG_INSPECTOR=0` starts with the inspector hidden.
    @State private var showsInspector = ProcessInfo.processInfo.environment["LUMEN_CATALOG_INSPECTOR"] != "0"
    /// Page colors picked in the inspector; they recolor the sidebar tiles live.
    @State private var hues: [CatalogPage: LumenToken] = [:]
    /// `LUMEN_CATALOG_PAGE=menus` opens a page directly (for screenshots and demos): its case name
    /// or title, exactly.
    @State private var page: CatalogPage? = (ProcessInfo.processInfo.environment["LUMEN_CATALOG_PAGE"]
        ?? (Bundle.main.object(forInfoDictionaryKey: "LumenCatalogPreviewInitialPage") as? String))
        .flatMap { name in CatalogPage.allCases.first { [$0.rawValue, "\($0)"].map { $0.lowercased() }.contains(name.lowercased()) } }
        ?? .overview
    @Environment(\.lumenPalette) private var palette

    private var pageContent: some View {
        // `LUMEN_CATALOG_SCROLL=bottom` scrolls the page to its end (for screenshots).
        ScrollViewReader { proxy in
            ScrollView {
                CatalogPageView(page: page ?? .overview)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                Color.clear.frame(height: 1).id("catalog.bottom")
            }
            .task(id: page) {
                guard ProcessInfo.processInfo.environment["LUMEN_CATALOG_SCROLL"] == "bottom" else { return }
                try? await Task.sleep(for: .milliseconds(300))
                proxy.scrollTo("catalog.bottom", anchor: .bottom)
            }
        }
        .background(palette[.bgCanvas])
        .frame(minWidth: CatalogLayout.pageMinWidth)
    }

    private var inspectorContent: some View {
        CatalogInspector(page: page ?? .overview, hue: Binding(
            get: { hues[page ?? .overview] ?? (page ?? .overview).hue },
            set: { hues[page ?? .overview] = $0 }))
    }

    private var sidebarContent: some View {
        // Drawn in the theme, not the system's blue list highlight.
        LumenSourceList(CatalogPage.allCases.map { page in
            LumenSourceListItem(id: page.rawValue, title: page.rawValue, systemImage: page.symbol, hue: hues[page] ?? page.hue)
        }, selection: Binding(get: { page?.rawValue }, set: { id in page = CatalogPage.allCases.first { $0.rawValue == id } }))
    }

    /// One native split gives older systems all three column minima together.
    private var legacyColumns: some View {
        HSplitView {
            if showsSidebar {
                sidebarContent
                    .frame(minWidth: CatalogLayout.sidebarMinWidth, idealWidth: CatalogLayout.sidebarIdealWidth, maxWidth: 300)
            }
            pageContent
            if showsInspector { LumenInspectorPane { inspectorContent } }
        }
        .lumenPanelCommands(leading: $showsSidebar, trailing: $showsInspector)
    }

    @ViewBuilder
    private var columns: some View {
        if usesLegacyColumns {
            legacyColumns
        } else {
            NavigationSplitView {
                sidebarContent
                    .navigationSplitViewColumnWidth(min: CatalogLayout.sidebarMinWidth, ideal: CatalogLayout.sidebarIdealWidth, max: 300)
            } detail: {
                pageContent
                    .lumenPanelCommands(trailing: $showsInspector)
                    .lumenInspector(isPresented: $showsInspector) { inspectorContent }
            }
        }
    }

    var body: some View {
        columns
        .navigationTitle("")
        .lumenCommandPalette(isPresented: $showsPalette, commands: paletteCommands, scopes: CatalogPalette.scopes,
                             recentsKey: "catalog.palette.recents", query: CatalogPalette.query, shortcut: nil)
        .toolbar {
            if usesLegacyColumns {
                ToolbarItem(placement: .navigation) {
                    LumenPanelToggle(edge: .leading, isOn: $showsSidebar, registersShortcut: false)
                }
            }
            ToolbarItem(placement: .navigation) {
                LumenToolbarIdentity("Lumen Catalog", subtitle: "~/Projects/Lumen", systemImage: "lumen.lens", hue: .hueViolet)
            }
            // Nothing while idle, as the unified bar's status (§9 item 4): no "Ready" pill.
            ToolbarItem(placement: .principal) { LumenToolbarStatus(activity, width: 300) }
            ToolbarItem(placement: .primaryAction) { LumenTaskCluster(tasks, activity: activity) }
            ToolbarItem(placement: .primaryAction) { LumenInspectorToggle(isPresented: $showsInspector, registersShortcut: false) }
        }
        .task {
            // `LUMEN_CATALOG_WELCOME=1` opens the welcome window; `LUMEN_CATALOG_ACTIVITY=working`
            // starts a long task (for screenshots and demos).
            if ProcessInfo.processInfo.environment["LUMEN_CATALOG_WELCOME"] == "1" { openWindow(id: "welcome") }
            // `LUMEN_CATALOG_WORKSPACE=1` opens the workspace window; `LUMEN_CATALOG_SPLIT=1` the
            // MacScope-shaped split workspace.
            if ProcessInfo.processInfo.environment["LUMEN_CATALOG_WORKSPACE"] == "1" { openWindow(id: "workspace") }
            if ProcessInfo.processInfo.environment["LUMEN_CATALOG_SPLIT"] == "1" { openWindow(id: "split") }
            if ProcessInfo.processInfo.environment["LUMEN_CATALOG_ACTIVITY"] == "working" {
                activity = .working("Analyzing libsystem_kernel.dylib", progress: 0.42)
            }
            if CatalogPalette.opens && ProcessInfo.processInfo.environment["LUMEN_CATALOG_WORKSPACE"] != "1" {
                try? await Task.sleep(for: .seconds(4.5))
                showsPalette = true
            }
            // `LUMEN_CATALOG_SETTINGS=1` also opens the Settings window (for screenshots and demos).
            if ProcessInfo.processInfo.environment["LUMEN_CATALOG_SETTINGS"] == "1" {
                try? await Task.sleep(for: .milliseconds(600))
                openSettings()
            }
        }
    }
}

/// Keep the window minimum outside the native columns' sizing preferences. Older systems
/// otherwise add the leading column to this whole-window minimum a second time.
struct CatalogWindowMinimum: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 27, *) {
            content.frame(minWidth: CatalogLayout.windowMinWidth, minHeight: 640)
        } else {
            GeometryReader { _ in content }
                .frame(minWidth: CatalogLayout.windowMinWidth, minHeight: 640)
        }
    }
}

/// The Catalog window's columns. A window never cuts its content off: each column has a minimum its
/// content fits (LumenCatalogTests measures every page), and the window's minimum is their sum.
enum CatalogLayout {
    static let sidebarMinWidth: CGFloat = 190
    static let pageMinWidth: CGFloat = 480
    static let readableContentMaxWidth: CGFloat = 960

    static func contentMaxWidth(for page: CatalogPage) -> CGFloat {
        switch page {
        case .workspace, .data, .browse, .debugger, .editor: .infinity
        default: readableContentMaxWidth
        }
    }
    /// What NavigationSplitView actually gives the inspector at the window's minimum: its ideal
    /// (280), not its 220 minimum. Measured in a real window: at the
    /// old 890 minimum the split view was 970 wide, centred at x −40, so the sidebar's leading edge
    /// (tiles, first letters) ran off the window. The minimum covers the split's real width.
    static let inspectorWidthAtMinimum: CGFloat = LumenLayout.inspectorColumn.ideal
    /// The sidebar's ideal, which NSV also keeps at the window's minimum (measured: at 952 the split
    /// was still 972 wide, the sidebar at 210 and 10 pt of it off the leading edge).
    static let sidebarIdealWidth: CGFloat = 210
    /// The split's real width at its minimum: sidebar and inspector at their ideals, the page at its
    /// minimum, plus NSV's two dividers.
    static let windowMinWidth = sidebarIdealWidth + pageMinWidth + inspectorWidthAtMinimum + 2
}

/// A fixed-size design (a window, the showcase) shown whole: scaled down to the width it's given,
/// never clipped. `maxScale` caps it (the welcome window reads best at 80%).
struct CatalogScaledPreview<Content: View>: View {
    let width: CGFloat
    let height: CGFloat
    var maxScale: CGFloat = 1
    @ViewBuilder let content: Content

    var body: some View {
        GeometryReader { proxy in
            let scale = min(maxScale, proxy.size.width / width)
            content
                .frame(width: width, height: height)
                .scaleEffect(scale, anchor: .topLeading)
                .frame(width: width * scale, height: height * scale, alignment: .topLeading)
        }
        .aspectRatio(width / height, contentMode: .fit)
        .frame(maxWidth: width * maxScale)
    }
}

/// One Catalog page with its margins. Each fits `CatalogLayout.pageMinWidth` (LumenCatalogTests).
struct CatalogPageView: View {
    let page: CatalogPage

    var body: some View {
        Group {
            switch page {
            case .overview: OverviewPage()
            case .welcome: WelcomePage()
            case .toolbar: ToolbarPage()
            case .tiles: TilesPage()
            case .menus: MenusPage()
            case .settings: SettingsPage()
            case .popovers: PopoversPage()
            case .glyphs: GlyphsPage()
            case .components: ComponentsPage()
            case .forms: FormsPage()
            case .search: SearchPage()
            case .data: DataPage()
            case .browse: BrowsePage()
            case .workspace: WorkspacePage()
            case .states: StatesPage()
            case .debugger: DebuggerPage()
            case .editor: EditorPage()
            case .sheets: SheetsPage()
            case .themes: ThemesPage()
            }
        }
        .frame(maxWidth: CatalogLayout.contentMaxWidth(for: page), alignment: .leading)
        .padding(28)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// `LUMEN_CATALOG_PALETTE=1` opens the command palette after launch; any other value opens it with
/// that query (for screenshots).
enum CatalogPalette {
    static let value = ProcessInfo.processInfo.environment["LUMEN_CATALOG_PALETTE"]
    static var opens: Bool { value != nil }
    static var query: String { value == nil || value == "1" ? "" : value! }

    /// The palette's scopes: everything, or pages (/), commands (>) or themes (@) alone.
    static let scopes = [LumenPaletteScope("All", prefix: nil), LumenPaletteScope("Pages", prefix: "/"),
                         LumenPaletteScope("Commands", prefix: ">"), LumenPaletteScope("Themes", prefix: "@")]

    /// Each command placed in its scope: Go commands in Pages, themes in Themes, the rest in Commands.
    static func scoped(_ commands: [LumenCommand]) -> [LumenCommand] {
        commands.map { command in
            var command = command
            command.scope = command.category == "Go" ? "Pages" : command.category == "Theme" ? "Themes" : "Commands"
            return command
        }
    }

    /// Theme commands, shared by both windows.
    @MainActor static func themes() -> [LumenCommand] {
        let store = LumenThemeStore.active
        return store.themes.map { theme in
            LumenCommand(id: "theme.\(theme.id)", "Use \(theme.name) Theme", subtitle: theme.summary, category: "Theme",
                         systemImage: "paintpalette.fill", hue: .hueOrange, keywords: ["appearance", "colors"],
                         isEnabled: store.theme(for: .window).id != theme.id) { store.select(theme.id) }
        }
    }
}

extension CatalogView {
    var paletteCommands: [LumenCommand] {
        CatalogPalette.scoped(unscopedCommands)
    }

    private var unscopedCommands: [LumenCommand] {
        CatalogPage.allCases.map { target in
            LumenCommand(id: "go.\(target.rawValue)", "Go to \(target.rawValue)", category: "Go", systemImage: target.symbol,
                         hue: target.hue, isEnabled: target != page) { page = target }
        } + [
            LumenCommand(id: "window.workspace", "Open Workspace", subtitle: "A three-pane layout in Lumen pieces", category: "Window",
                         systemImage: "macwindow", hue: .hueViolet) { openWindow(id: "workspace") },
            LumenCommand(id: "window.welcome", "Open Welcome Window", category: "Window", systemImage: "hand.wave.fill",
                         hue: .hueYellow) { openWindow(id: "welcome") },
            LumenCommand(id: "window.settings", "Settings…", category: "Window", systemImage: "gearshape.fill", hue: .hueGraphite,
                         shortcut: KeyboardShortcut(",")) { openSettings() },
            LumenCommand(id: "view.inspector", showsInspector ? "Hide Inspector" : "Show Inspector", category: "View",
                         systemImage: "sidebar.trailing", hue: .hueBlue, shortcut: LumenShortcuts.inspector) { showsInspector.toggle() },
        ] + tasks.map { task in
            LumenCommand(id: "task.\(task.title)", task.title, category: "Tasks", systemImage: task.systemImage,
                         hue: task.role == .stop ? .hueRed : task.role == .start ? .hueGreen : .hueIndigo, shortcut: task.shortcut,
                         isEnabled: task.role == .stop ? activity.isBusy : !activity.isBusy || task.role == .normal, perform: task.perform)
        } + CatalogPalette.themes()
    }

    /// Build, Run and Stop drive the toolbar's live activity, as a real app's tasks would.
    var tasks: [LumenTaskAction] {
        [
            LumenTaskAction("Build", systemImage: "hammer.fill", shortcut: KeyboardShortcut("b", modifiers: [.command])) {
                run("Building Lumen…", steps: 12, result: .succeeded("Build succeeded"))
            },
            LumenTaskAction("Run", systemImage: "play.fill", role: .start, shortcut: KeyboardShortcut("r", modifiers: [.command])) {
                run("Analyzing libsystem_kernel.dylib", steps: 40, result: .succeeded("Analysis finished: 1,284 functions"))
            },
            LumenTaskAction("Stop", systemImage: "stop.fill", role: .stop, shortcut: KeyboardShortcut(".", modifiers: [.command])) {
                job?.cancel()
                activity = .failed("Stopped")
            },
        ]
    }

    func run(_ label: String, steps: Int, result: LumenActivity) {
        job?.cancel()
        job = Task { @MainActor in
            for step in 0...steps {
                activity = .working(label, progress: Double(step) / Double(steps))
                try? await Task.sleep(for: .milliseconds(80))
                if Task.isCancelled { return }
            }
            activity = result
        }
    }
}

struct PageHeader: View {
    let title: String
    let summary: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.title2.weight(.semibold))
            Text(summary).foregroundStyle(.lumen(.fgSecondary))
        }
        .padding(.bottom, 12)
    }
}

struct ThemesPage: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(title: "Themes", summary: "Every theme the app offers, as a miniature of its window. Click one to use it; drop a theme file here to add it.")
            LumenThemeGallery()
        }
    }
}

struct OverviewPage: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(title: "Lumen", summary: "Native structure, expressive surface. Every color here comes from the theme and passes the validator.")
            CatalogScaledPreview(width: 620, height: 360) { LumenShowcase() }
        }
    }
}

/// The Catalog's inspector: what the selected page is, the live theme, and the page's color.
struct CatalogInspector: View {
    let page: CatalogPage
    @Binding var hue: LumenToken
    @SceneStorage("inspector.theme") private var themeExpanded = true
    @SceneStorage("inspector.page") private var pageExpanded = true
    private var store: LumenThemeStore { .active }

    var body: some View {
        LumenInspectorHeader(page.rawValue, subtitle: "Catalog page", systemImage: page.symbol, hue: hue)
        LumenInspectorSection("Theme", systemImage: "paintpalette.fill", hue: .hueOrange, isExpanded: $themeExpanded) {
            LumenInspectorRow("Theme") {
                Picker("Theme", selection: Binding(get: { store.theme(for: .window).id }, set: { store.select($0) })) {
                    ForEach(store.themes) { Text($0.name).tag($0.id) }
                }
            }
            LumenInspectorRow("Accent") {
                HStack(spacing: 6) {
                    Toggle("Use system accent", isOn: Binding(get: { store.usesSystemAccent }, set: { store.setUsesSystemAccent($0) }))
                        .toggleStyle(.checkbox).labelsHidden()
                    Text("System").font(.caption).foregroundStyle(.lumen(.fgSecondary))
                    LumenInfoButton("System Accent", message: "Draws accent roles in the color chosen in System Settings › Appearance, instead of the theme’s own.")
                }
            }
        }
        LumenInspectorSection("Page", systemImage: "doc.richtext.fill", hue: .hueBlue, isExpanded: $pageExpanded) {
            LumenInspectorRow("Color") { LumenHuePickerButton(selection: $hue) }
            LumenPropertyRow(label: "Symbol", value: page.symbol)
            LumenPropertyRow(label: "Hue token", value: hue.rawValue)
        }
        LumenInspectorSection("About", systemImage: "info", hue: .hueGraphite) {
            Text("Inspectors hold the selection’s properties in collapsible sections with native controls. Hide this one with ⌥⌘I.")
                .font(.caption).foregroundStyle(.lumen(.fgSecondary)).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct PopoversPage: View {
    @State private var hue: LumenToken = .hueTeal
    @State private var sharing = false
    @State private var details = false
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PageHeader(title: "Popovers", summary: "Native popovers (system material, arrow, click-away and Escape) with Lumen’s tile header, content and footer.")
            LumenSectionHeader("Info buttons")
            HStack(spacing: 8) {
                Text("Increase Contrast variants")
                LumenInfoButton("Increase Contrast", message: "Themes define a stronger variant for each appearance. Lumen switches to it when the system setting is on.")
            }
            LumenSectionHeader("Color")
            HStack(spacing: 10) {
                LumenHuePickerButton("Label Color", selection: $hue)
                LumenIconTile("tag.fill", hue: hue, size: 22)
            }
            LumenSectionHeader("Popover with actions")
            HStack(spacing: 12) {
                Button("Share Theme…", systemImage: "square.and.arrow.up") { sharing = true }
                    .popover(isPresented: $sharing, arrowEdge: .bottom) {
                        LumenPopoverContent("Share Theme", subtitle: "Lumen · light and dark", systemImage: "square.and.arrow.up.fill", hue: .hueBlue) {
                            Text("Exports a .json theme file that anyone with a Lumen app can import.")
                                .fixedSize(horizontal: false, vertical: true)
                        } footer: {
                            Button("Cancel") { sharing = false }
                            Button("Export…") { sharing = false }.keyboardShortcut(.defaultAction)
                        }
                    }
                Button("Build Details", systemImage: "hammer") { details = true }
                    .lumenPopover(isPresented: $details, title: "Build succeeded", subtitle: "12.4 s · 0 warnings",
                                  systemImage: "checkmark", hue: .hueGreen) {
                        LumenPropertyRow(label: "Scheme", value: "Lumen")
                        LumenPropertyRow(label: "Configuration", value: "Debug", monospaced: false)
                    }
            }
        }
        .task {
            // `LUMEN_CATALOG_POPOVER=1` opens the share popover (for screenshots and demos).
            if ProcessInfo.processInfo.environment["LUMEN_CATALOG_POPOVER"] == "1" {
                try? await Task.sleep(for: .milliseconds(400))
                sharing = true
            }
        }
    }
}

struct WelcomePage: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(title: "Welcome", summary: "Personality at the edges: the app’s mark over a starfield that surges when you hover the primary action. Still under Reduce Motion.")
            Button { openWindow(id: "welcome") } label: { Label("Open the Welcome Window", systemImage: "macwindow") }
            // The real window, scaled to the page's width (at most 80%).
            CatalogScaledPreview(width: 760, height: 460, maxScale: 0.8) {
                CatalogWelcome()
                    .clipShape(.rect(cornerRadius: 12))
                    .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(.lumen(.borderSubtle)) }
            }
        }
    }
}

struct CatalogWelcome: View {
    @AppStorage("catalog.showWelcome") private var showAtLaunch = true
    var body: some View {
        LumenWelcomeView(
            appName: "Lumen", version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev", tagline: "A design system for Mac apps with character.",
            markSymbol: "lumen.lens", markHue: .hueViolet,
            actions: [
                LumenWelcomeAction("New Project", subtitle: "Start from a template", systemImage: "plus", hue: .hueViolet,
                                   shortcut: KeyboardShortcut("n", modifiers: [.command]), isPrimary: true) {},
                LumenWelcomeAction("Open…", subtitle: "Browse for a project", systemImage: "folder.fill", hue: .hueBlue,
                                   shortcut: KeyboardShortcut("o", modifiers: [.command])) {},
                LumenWelcomeAction("Clone Repository…", systemImage: "arrow.down", hue: .hueTeal) {},
            ],
            recents: [
                LumenRecentItem(title: "Lumen", detail: "~/Projects/Lumen", date: .now.addingTimeInterval(-600), systemImage: "lumen.lens", hue: .hueViolet),
                LumenRecentItem(title: "MacScope", detail: "~/Projects/MacScope", date: .now.addingTimeInterval(-86_400), systemImage: "scope", hue: .hueIndigo),
                LumenRecentItem(title: "Field Notes", detail: "~/Documents/Field Notes", date: .now.addingTimeInterval(-3 * 86_400), systemImage: "book.closed.fill", hue: .hueOrange),
                LumenRecentItem(title: "Scans", detail: "~/Documents/Scans", date: .now.addingTimeInterval(-9 * 86_400), systemImage: "doc.viewfinder.fill", hue: .hueTeal),
            ],
            showAtLaunch: $showAtLaunch
        )
    }
}

struct ToolbarPage: View {
    private let states: [LumenActivity] = [.idle(), .working("Analyzing libsystem_kernel.dylib", progress: 0.42),
                                           .working("Indexing symbols"), .succeeded("Build succeeded"), .failed("2 errors")]
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(title: "Toolbar", summary: "The toolbar stays native. Inside it: the project’s identity, a live activity status and a task cluster. Try Build (⌘B), Run (⌘R) and Stop (⌘.) above.")
            ForEach(Array(states.enumerated()), id: \.offset) { _, state in
                LumenActivityStatus(state, width: 360)
            }
        }
    }
}

extension LumenGlyph {
    /// An app's own glyph, registered at launch: a page with a corner tab.
    static let catalogPage = LumenGlyph(id: "catalog.page", title: "Catalog Page", family: "Catalog (registered)") { d in
        var page = Path()
        page.addRoundedRect(in: CGRect(x: 5, y: 3, width: 14, height: 18), cornerSize: CGSize(width: 2.5, height: 2.5), style: .continuous)
        d.stroke.addPath(page)
        d.tint.addPath(page)
        d.fill.addRoundedRect(in: CGRect(x: 12.5, y: 1.5, width: 5, height: 7), cornerSize: CGSize(width: 1.2, height: 1.2))
        d.stroke.move(to: CGPoint(x: 8, y: 12)); d.stroke.addLine(to: CGPoint(x: 16, y: 12))
        d.stroke.move(to: CGPoint(x: 8, y: 16)); d.stroke.addLine(to: CGPoint(x: 13.5, y: 16))
    }
}

struct GlyphsPage: View {
    @State private var selected: LumenGlyph = .callGraph
    private let hues: [LumenToken] = [.hueViolet, .hueIndigo, .hueBlue, .hueTeal, .hueGreen, .hueYellow, .hueOrange, .hueRed, .huePink]

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PageHeader(title: "Glyphs", summary: "Symbols SF Symbols doesn’t have. Each draws as an SF Symbol: a custom one built from Apple’s geometry, or an SF equivalent, outlined beside text and filled on tiles. Pass a glyph’s name (lumen.callGraph) anywhere Lumen takes a systemImage.")
            ForEach(LumenGlyph.families, id: \.self) { family in
                LumenSectionHeader(family)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 12)], alignment: .leading, spacing: 12) {
                    ForEach(Array(LumenGlyph.all.filter { $0.family == family }.enumerated()), id: \.element.id) { index, glyph in
                        Button { selected = glyph } label: {
                            VStack(spacing: 6) {
                                LumenIconTile(glyph.symbolName, hue: hues[index % hues.count], size: 40)
                                Text(glyph.title).font(.caption).foregroundStyle(.lumen(.fgPrimary)).lineLimit(1)
                                Text(glyph.symbolName).font(.caption2.monospaced()).foregroundStyle(.lumen(.fgTertiary)).lineLimit(1)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(.lumen(selected == glyph ? .bgSelected : .bgElevated), in: .rect(cornerRadius: 10))
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            LumenSectionHeader("Sizes and places")
            // Side by side when there's room, stacked when there isn't.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .bottom, spacing: 22) {
                    sizes
                    Divider().frame(height: 48)
                    places
                    Divider().frame(height: 48)
                    glyphMenu
                }
                VStack(alignment: .leading, spacing: 16) {
                    sizes
                    places
                    glyphMenu
                }
            }
        }
    }

    private var sizes: some View {
        HStack(alignment: .bottom, spacing: 22) {
            ForEach([12, 16, 24, 32, 48] as [CGFloat], id: \.self) { size in
                VStack(spacing: 6) {
                    LumenSymbol(selected.symbolName, size: size).foregroundStyle(.lumen(.fgPrimary))
                    Text("\(Int(size)) pt").font(.caption).foregroundStyle(.lumen(.fgTertiary))
                }
            }
        }
    }

    private var places: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                LumenBadge("Analyzed", systemImage: selected.symbolName, tone: .success)
                LumenPill(label: "Kind", value: selected.title, systemImage: selected.symbolName)
            }
            Label { Text("Follows the font, like an SF Symbol") } icon: { LumenSymbol(selected.symbolName) }
                .font(.title3).foregroundStyle(.lumen(.accent))
        }
    }

    private var glyphMenu: some View {
        Menu {
            ForEach(LumenGlyph.all.prefix(8)) { glyph in
                Button {} label: { Label { Text(glyph.title) } icon: { glyph.image() } }
            }
        } label: {
            Label("Native Menu", systemImage: "filemenu.and.selection")
        }
        .fixedSize()
        .help("Template images: the menu tints them, including the highlight")
    }
}

struct TilesPage: View {
    private let symbols = ["star.fill", "paintpalette.fill", "bolt.fill", "leaf.fill", "drop.fill", "sun.max.fill",
                           "flame.fill", "heart.fill", "sparkles", "gearshape.fill"]
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PageHeader(title: "Icon Tiles", summary: "A categorical hue family for navigation and categories. In light mode the hue is the tile and its symbol stays white wherever it reaches 3:1; in dark mode the tile is dark slate and the symbol takes the hue.")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 52), spacing: 14, alignment: .top)], alignment: .leading, spacing: 14) {
                ForEach(Array(LumenToken.hues.enumerated()), id: \.offset) { index, hue in
                    VStack(spacing: 6) {
                        LumenIconTile(symbols[index], hue: hue, size: 40)
                        Text(hue.rawValue.replacingOccurrences(of: "hue.", with: "").capitalized).font(.caption).foregroundStyle(.lumen(.fgSecondary))
                    }
                }
            }
            HStack(alignment: .bottom, spacing: 18) {
                ForEach([16, 20, 28, 40, 64] as [CGFloat], id: \.self) { size in
                    VStack(spacing: 6) {
                        LumenIconTile("paintpalette.fill", hue: .hueViolet, size: size)
                        Text("\(Int(size)) pt").font(.caption).foregroundStyle(.lumen(.fgTertiary))
                    }
                }
            }
        }
    }
}

struct MenusPage: View {
    /// `LUMEN_CATALOG_COMMANDS=1` opens the command menu popover (for screenshots and demos).
    @State private var showCommands = ProcessInfo.processInfo.environment["LUMEN_CATALOG_COMMANDS"] == "1"
    static let entries: [LumenMenuEntry] = [
        .section("Navigate"),
        .item("Go to Address…", subtitle: "Jump to any address or symbol", systemImage: "number", hue: .hueBlue,
              shortcut: KeyboardShortcut("g", modifiers: [.command])),
        .item("Find in Project", systemImage: "magnifyingglass", hue: .hueTeal, shortcut: KeyboardShortcut("f", modifiers: [.command, .shift])),
        .submenu("Open Recent", systemImage: "clock.fill", hue: .hueOrange, [
            .item("Calculator.app", systemImage: "app.fill", hue: .hueGraphite),
            .item("libsystem_kernel.dylib", systemImage: "shippingbox.fill", hue: .hueIndigo),
            .separator("recent"),
            .item("Clear Menu"),
        ]),
        .separator("main"),
        .section("View"),
        .item("Show Inspector", systemImage: "sidebar.right", hue: .hueViolet, shortcut: KeyboardShortcut("i", modifiers: [.command, .option]), isChecked: true),
        .item("Compact Rows", systemImage: "rectangle.compress.vertical", hue: .hueGreen, isEnabled: false),
        .separator("end"),
        .item("Delete Bookmark", systemImage: "trash.fill", hue: .hueRed, isDestructive: true),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            PageHeader(title: "Menus", summary: "Menu-bar and context menus stay native and gain colored tiles. The command menu is Lumen’s one custom menu surface.")
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    Menu {
                        Button {} label: { LumenMenuLabel("Go to Address…", systemImage: "number", hue: .hueBlue) }.keyboardShortcut("g")
                        Menu {
                            Button {} label: { LumenMenuLabel("Calculator.app", systemImage: "app.fill", hue: .hueGraphite) }
                            Button {} label: { LumenMenuLabel("libsystem_kernel.dylib", systemImage: "shippingbox.fill", hue: .hueIndigo) }
                        } label: { LumenMenuLabel("Open Recent", systemImage: "clock.fill", hue: .hueOrange) }
                        Divider()
                        Button(role: .destructive) {} label: { LumenMenuLabel("Delete Bookmark", systemImage: "trash.fill", hue: .hueRed) }
                    } label: {
                        Label("Native Menu", systemImage: "filemenu.and.selection")
                    }
                    .fixedSize()
                    Button { showCommands = true } label: { Label("Command Menu", systemImage: "command") }
                        .lumenCommandMenu(isPresented: $showCommands, entries: Self.entries)
                        .fixedSize()
                }
                // Under the buttons, so they keep their labels at the window's minimum.
                Text("Right-click the card below for a context menu, or use the Lumen menu in the menu bar.")
                    .font(.callout).foregroundStyle(.lumen(.fgTertiary))
                    .lumenWrapsWithoutTruncating()
            }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 24) { commandMenu; contextCard }
                VStack(alignment: .leading, spacing: 24) { commandMenu; contextCard }
            }
        }
    }

    private var commandMenu: some View { LumenCommandMenu(Self.entries) }

    private var contextCard: some View {
                RoundedRectangle(cornerRadius: 10).fill(.lumen(.bgElevated))
                    .overlay { Text("Right-click me").foregroundStyle(.lumen(.fgSecondary)) }
                    .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(.lumen(.borderSubtle)) }
                    .frame(width: 220, height: 140)
                    .contextMenu {
                        Button {} label: { LumenMenuLabel("Copy Address", systemImage: "doc.on.doc.fill", hue: .hueBlue) }
                        Button {} label: { LumenMenuLabel("Add Bookmark", systemImage: "bookmark.fill", hue: .hueYellow) }
                        Menu {
                            Button {} label: { LumenMenuLabel("Red", systemImage: "circle.fill", hue: .hueRed) }
                            Button {} label: { LumenMenuLabel("Green", systemImage: "circle.fill", hue: .hueGreen) }
                            Button {} label: { LumenMenuLabel("Blue", systemImage: "circle.fill", hue: .hueBlue) }
                        } label: { LumenMenuLabel("Tag", systemImage: "tag.fill", hue: .huePink) }
                    }
    }
}

struct SettingsPage: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PageHeader(title: "Settings", summary: "A separate window (⌘,) with colored tabs, native grouped forms and native controls; changes apply at once.")
            HStack(spacing: 12) {
                SettingsLink { Label("Open Settings…", systemImage: "gearshape") }
                Text("Below: the sidebar layout for apps with many categories.").font(.callout).foregroundStyle(.lumen(.fgTertiary))
            }
            // At its real minimum (sidebar + pane), scaled to the page as the other fixed designs
            // are, so the pane's rows never squeeze into truncated values.
            CatalogScaledPreview(width: LumenSettingsSidebarView.sidebarMinWidth + LumenSettingsSidebarView.detailMinWidth + 60, height: 420) {
                LumenSettingsSidebarView(CatalogSettings.categories)
                    .clipShape(.rect(cornerRadius: 10))
                    .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(.lumen(.borderSubtle)) }
            }
        }
    }
}

struct ComponentsPage: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PageHeader(title: "Components", summary: "Badges, pills, tags, property rows, keycaps, empty states, progress, markers and app icons. Forms, search, data, browsing and workspace pieces have pages of their own.")
            HStack(spacing: 8) { ForEach(LumenBadge.Tone.allCases, id: \.self) { LumenBadge("\($0)".capitalized, tone: $0) } }
            HStack(spacing: 8) {
                LumenPill(label: "version", value: "2.4.1")
                LumenPill(label: "items", value: "1,284", style: .metric)
                LumenTag("pinned", token: .accent)
                LumenTag("review", token: .hueOrange)
            }
            HStack(spacing: 14) {
                LumenKeycap(KeyboardShortcut("k", modifiers: [.command]))
                LumenKeycap(KeyboardShortcut("f", modifiers: [.command, .shift]))
                LumenKeycap(["⌃", "Space"])
            }
            VStack(spacing: 0) {
                LumenPropertyRow(label: "Owner", value: "Avery", monospaced: false)
                LumenPropertyRow(label: "Identifier", value: "0x1000a3e1c")
            }.frame(width: 360)
            LumenEmptyState(systemImage: "tray", title: "Nothing here yet", message: "Items you add appear in this list.",
                            actionTitle: "Add item") {}
                .frame(width: 360, height: 220)
            LumenSectionHeader("Progress, markers and literals")
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    LumenProgressBar(0.6).frame(width: 160)
                    LumenProgressBar(nil).frame(width: 120)
                    LumenProgressRing(progress: 0.35).frame(width: 16, height: 16)
                    LumenProgressRing(progress: nil).frame(width: 16, height: 16)
                }
                HStack(spacing: 12) {
                    LumenSymbolBadge(systemImage: "lumen.breakpoint", token: .hueBlue, label: "Breakpoint")
                    LumenBreakpointMarker(isOn: $breakpoint, label: "Line 42")
                    LumenStringLiteral("\"Hello, MacScope!\\n\"")
                }
                LumenFormRow("Process") {
                    TextField("Process", text: $process).textFieldStyle(.roundedBorder).frame(width: 200)
                }
                LumenSidebarCountSection("Bookmarks", systemImage: "bookmark.fill", hue: .hueYellow, count: 0,
                                         emptyMessage: "Bookmark an address to find it here.") { EmptyView() }
                    .frame(width: 260).lumenSidebarBackground().clipShape(.rect(cornerRadius: 8))
                HStack(spacing: 12) {
                    LumenAppIcon("lumen.lens", hue: .hueViolet, size: 64)
                    LumenAppIcon("scope", hue: .hueIndigo, size: 64)
                    Text("App icons drawn from a symbol and a hue, for the Dock and the welcome window.")
                        .font(.caption).foregroundStyle(.lumen(.fgTertiary)).frame(width: 200, alignment: .leading)
                }
            }
        }
    }

    @State private var breakpoint = true
    @State private var process = "Sample"
}

// MARK: Settings window

struct CatalogSettings: View {
    var body: some View {
        TabView {
            GeneralSettings().lumenSettingsTab("General", systemImage: "gearshape.fill", hue: .hueGraphite)
            AppearanceSettings().lumenSettingsTab("Appearance", systemImage: "paintpalette.fill", hue: .hueViolet)
            ShortcutSettings().lumenSettingsTab("Shortcuts", systemImage: "command", hue: .hueBlue)
            PrivacySettings().lumenSettingsTab("Privacy", systemImage: "hand.raised.fill", hue: .hueTeal)
        }
    }

    static let categories: [LumenSettingsCategory] = [
        LumenSettingsCategory(id: "general", title: "General", systemImage: "gearshape.fill", hue: .hueGraphite,
                              keywords: ["startup", "updates"]) { GeneralSettings() },
        LumenSettingsCategory(id: "appearance", title: "Appearance", systemImage: "paintpalette.fill", hue: .hueViolet,
                              keywords: ["theme", "accent", "density"]) { AppearanceSettings() },
        LumenSettingsCategory(id: "shortcuts", title: "Shortcuts", systemImage: "command", hue: .hueBlue,
                              keywords: ["keyboard"]) { ShortcutSettings() },
        LumenSettingsCategory(id: "privacy", title: "Privacy", systemImage: "hand.raised.fill", hue: .hueTeal,
                              keywords: ["network", "analytics"]) { PrivacySettings() },
        LumenSettingsCategory(id: "notifications", title: "Notifications", systemImage: "bell.badge.fill", hue: .hueRed,
                              keywords: ["alerts"]) { NotificationSettings() },
    ]
}

struct GeneralSettings: View {
    @AppStorage("catalog.reopen") private var reopen = true
    @AppStorage("catalog.updates") private var updates = true
    @AppStorage("catalog.startup") private var startup = "welcome"
    var body: some View {
        LumenSettingsPane("General", systemImage: "gearshape.fill", hue: .hueGraphite,
                          summary: "How the app starts and stays up to date.") {
            Picker("On launch, show", selection: $startup) {
                Text("Welcome window").tag("welcome")
                Text("Last project").tag("last")
                Text("Nothing").tag("none")
            }
            Toggle("Reopen windows from last time", isOn: $reopen).toggleStyle(.checkbox)
            Toggle("Check for updates automatically", isOn: $updates).toggleStyle(.checkbox)
        }
    }
}

struct AppearanceSettings: View {
    var body: some View { LumenAppearanceSettings(showsGallery: false) }
}

struct ShortcutSettings: View {
    var body: some View {
        LumenSettingsPane("Shortcuts", systemImage: "command", hue: .hueBlue, summary: "Keyboard shortcuts for common actions.") {
            LabeledContent("Go to Address") { LumenKeycap(KeyboardShortcut("g", modifiers: [.command])) }
            LabeledContent("Find in Project") { LumenKeycap(KeyboardShortcut("f", modifiers: [.command, .shift])) }
            LabeledContent("Show Inspector") { LumenKeycap(KeyboardShortcut("i", modifiers: [.command, .option])) }
        }
    }
}

struct PrivacySettings: View {
    @AppStorage("catalog.network") private var network = false
    var body: some View {
        LumenSettingsPane("Privacy", systemImage: "hand.raised.fill", hue: .hueTeal, summary: "Everything stays on this Mac unless you allow it.") {
            Toggle("Allow network access for symbol servers", isOn: $network).toggleStyle(.checkbox)
            LabeledContent("Analytics") { LumenBadge("Off", tone: .neutral) }   // an off setting is neutral, not a success
        }
    }
}

struct NotificationSettings: View {
    @AppStorage("catalog.notify") private var notify = true
    var body: some View {
        LumenSettingsPane("Notifications", systemImage: "bell.badge.fill", hue: .hueRed, summary: "When the app may alert you.") {
            Toggle("Notify when analysis finishes", isOn: $notify).toggleStyle(.checkbox)
        }
    }
}

// MARK: Workspace window

/// A workspace built from Lumen pieces: glowing title bar, panel toggles, sidebar switcher and
/// sections, document tabs, status bar, a bottom panel with console tabs, a dock zone, and the new menu.
struct WorkspaceDemo: View {
    private static let env = ProcessInfo.processInfo.environment
    @State private var columns: NavigationSplitViewVisibility = .all
    @State private var showsPanel = true
    @State private var showsDock = env["LUMEN_CATALOG_DOCK"] == "1"
    @State private var showsLaunch = false
    @State private var pane = "symbols"
    @AppStorage("catalog.workspace.paneArrangement") private var paneArrangement = ""
    @State private var filter = ""
    @State private var documents = WorkspaceDemoModel()
    @State private var panelTab = env["LUMEN_CATALOG_PANEL"] ?? "debug"
    @State private var syntax = "HTML"
    @State private var encoding = "UTF-8"
    @State private var lineEndings = "LF"
    @State private var indentation = "Tabs (4 sp)"
    @State private var log = WorkspaceDemo.sampleLog
    @State private var showsPalette = false
    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenMetrics) private var metrics

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            sidebar
                .lumenSidebarBackground()
                .toolbar(removing: .sidebarToggle)   // the leading panel toggle replaces it
                // Outermost, so NavigationSplitView reads it (inside `.toolbar(removing:)` the
                // sidebar rendered at 144 pt, under its minimum).
                // Six tabs need at least 780 pt; at the 1000 pt window minimum, the
                // visible navigator leaves at most 760 pt so the strip must scroll.
                .navigationSplitViewColumnWidth(min: 240, ideal: 240, max: 320)
        } detail: {
            editor
                .lumenBottomPanel(isPresented: $showsPanel) { bottomPanel }
                // The editor's own minimum (status bar, log console), so dragging the sidebar or the
                // dock wider can't squeeze it until it clips.
                .frame(minWidth: 420)
                .inspector(isPresented: $showsDock) {
                    LumenDropZone()
                        .background(palette[.inspectorBackground])
                        .inspectorColumnWidth(min: 180, ideal: 220, max: 300)
                }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                LumenToolbarBreadcrumb(["Lumen"], systemImage: "lumen.lens", hue: .hueViolet)
            }
            ToolbarItem(placement: .primaryAction) {
                // New right beside the toggles, in one item.
                HStack(spacing: 2) {
                LumenPanelToggles(leading: navigator, bottom: $showsPanel, trailing: $showsDock, registersShortcuts: false)
                LumenNewItemButton { showsLaunch = true }
                    .lumenLaunchMenu(isPresented: $showsLaunch, items: [
                        LumenLaunchItem("Document", systemImage: "doc.fill", hue: .hueGraphite, shortcut: KeyboardShortcut("n")) { documents.newDocument() },
                        LumenLaunchItem("Preview", systemImage: "eye.fill", hue: .hueBlue) {},
                        LumenLaunchItem("Local Terminal", systemImage: "terminal.fill", hue: .hueGreen) {},
                        LumenLaunchItem("Remote Terminal", systemImage: "globe", hue: .hueViolet) {},
                        LumenLaunchItem("File Browser", systemImage: "folder.fill", hue: .hueTeal) {},
                    ])
                }
            }
        }
        .focusedSceneValue(\.catalogNewDocument, { documents.newDocument() })
        .navigationTitle("")
        .lumenCommandPalette(isPresented: $showsPalette, commands: paletteCommands, recentsKey: "catalog.workspace.palette.recents",
                             query: CatalogPalette.query, shortcut: nil)
        .lumenPanelCommands(leading: navigator, bottom: $showsPanel, trailing: $showsDock)
        // View › Show <pane> (⌘1…⌘9) reveals a collapsed navigator; the menu owns every shortcut here.
        .lumenPaneCommands(Self.panes, selection: $pane, showsNavigator: navigator, arrangement: paneArrangement)
        .lumenMenuOwnsShortcuts()
        .lumenWindowChrome()
        .task {
            // `LUMEN_CATALOG_LOGSTREAM=1` appends a log line every 0.3 s (to see the console follow).
            guard Self.env["LUMEN_CATALOG_LOGSTREAM"] == "1" else { return }
            for index in 1...200 {
                try? await Task.sleep(for: .milliseconds(300))
                log.append(LumenLogEntry(date: .now, source: "Stream", level: index % 7 == 0 ? .warning : .log,
                                         message: "Streamed line \(index)"))
            }
        }
        .task {
            // `LUMEN_CATALOG_LAUNCH=<seconds>` opens the new menu after that delay (1 means half a second).
            if CatalogPalette.opens {
                try? await Task.sleep(for: .seconds(4.5))
                showsPalette = true
            }
            if let value = Self.env["LUMEN_CATALOG_LAUNCH"], let seconds = Double(value) {
                try? await Task.sleep(for: .seconds(value == "1" ? 0.5 : seconds))
                showsLaunch = true
            }
        }
    }

    private var paletteCommands: [LumenCommand] {
        let panels: [LumenCommand] = [
            LumenCommand(id: "view.navigator", columns == .detailOnly ? "Show Navigator" : "Hide Navigator", category: "View",
                         systemImage: "sidebar.leading", hue: .hueBlue, shortcut: LumenShortcuts.navigator) { navigator.wrappedValue.toggle() },
            LumenCommand(id: "view.panel", showsPanel ? "Hide Panel" : "Show Panel", category: "View",
                         systemImage: "rectangle.bottomthird.inset.filled", hue: .hueBlue, shortcut: LumenShortcuts.panel) { showsPanel.toggle() },
            LumenCommand(id: "view.dock", showsDock ? "Hide Inspector" : "Show Inspector", category: "View",
                         systemImage: "sidebar.trailing", hue: .hueBlue, shortcut: LumenShortcuts.inspector) { showsDock.toggle() },
        ]
        let documentCommands = documents.tabs.map { tab in
            LumenCommand(id: "open.\(tab.id)", "Open \(tab.title)", category: "Go", systemImage: tab.systemImage, hue: tab.hue,
                         keywords: ["file", "tab"], isEnabled: documents.selection != tab.id) { documents.selection = tab.id }
        }
        let consoles = [("debug", "Debug Console", "ladybug.fill"), ("console", "Extension Console", "puzzlepiece.extension.fill"),
                        ("transcript", "Transcript", "doc.plaintext")].map { id, title, symbol in
            LumenCommand(id: "panel.\(id)", "Show \(title)", category: "Panel", systemImage: symbol, hue: .hueTeal,
                         keywords: ["log", "console", "output"]) { showsPanel = true; panelTab = id }
        }
        let create = [("Document", "doc.fill", LumenToken.hueGraphite), ("Local Terminal", "terminal.fill", .hueGreen),
                      ("Remote Terminal", "globe", .hueViolet), ("File Browser", "folder.fill", .hueTeal)].map { title, symbol, hue in
            LumenCommand(id: "new.\(title)", "New \(title)", category: "New", systemImage: symbol, hue: hue) {
                if title == "Document" { documents.newDocument() }
            }
        }
        let clear = LumenCommand(id: "console.clear", "Clear Extension Console", category: "Panel", systemImage: "trash",
                                 hue: .hueRed, keywords: ["log"], isEnabled: !log.isEmpty) { log = [] }
        return panels + documentCommands + consoles + [clear] + create + CatalogPalette.themes()
    }

    private var navigator: Binding<Bool> {
        Binding(get: { columns != .detailOnly }, set: { columns = $0 ? .all : .detailOnly })
    }

    static let panes = [
        LumenSidebarItem(id: "files", title: "Files", systemImage: "folder"),
        LumenSidebarItem(id: "web", title: "Web", systemImage: "globe"),
        LumenSidebarItem(id: "search", title: "Search", systemImage: "magnifyingglass"),
        LumenSidebarItem(id: "symbols", title: "Symbols", systemImage: "list.bullet.indent"),
        LumenSidebarItem(id: "graph", title: "Call Graph", systemImage: "lumen.callGraph"),
        LumenSidebarItem(id: "git", title: "Source Control", systemImage: "arrow.triangle.branch"),
        LumenSidebarItem(id: "cloud", title: "Remote", systemImage: "icloud"),
    ]

    private var sidebar: some View {
        VStack(spacing: 0) {
            LumenSidebarSwitcher(selection: $pane, items: Self.panes, arrangement: $paneArrangement)
            LumenSidebarSection("Symbols") {
                LumenEmptyState.inline("No symbols in the current document", leading: true).padding(.horizontal, metrics.spacing.s4)
            }
            LumenSidebarSection("Open Pull Requests", actions: [LumenSidebarAction("New Pull Request", systemImage: "plus") {}]) {
                LumenEmptyState.inline("No open pull requests", leading: true).padding(.horizontal, metrics.spacing.s4)
            }
            LumenSidebarSection("Repositories", actions: [LumenSidebarAction("Clone Repository", systemImage: "square.on.square") {}]) {
                LumenEmptyState.inline("No repositories configured", leading: true).padding(.horizontal, metrics.spacing.s4)
            }
            // Anchored at the sidebar's foot, as in Lumen's workspace golden.
            Spacer(minLength: 0)
            LumenFilterField(text: $filter).padding(.horizontal, 10).padding(.vertical, 8)
        }
        .background(palette[.sidebarBackground])
    }

    private var editor: some View {
        VStack(spacing: 0) {
            LumenDocumentTabBar(documents.tabs, selection: $documents.selection,
                                onClose: { documents.close($0.id) })
            HStack(spacing: 8) {
                Image(systemName: "chevron.left"); Image(systemName: "chevron.right")
                Text("html › body › main").font(.callout)
                Spacer()
            }
            .foregroundStyle(palette[.fgTertiary])
            .padding(.horizontal, 12).frame(height: 26)
            .overlay(alignment: .bottom) { Rectangle().fill(palette[.borderSubtle]).frame(height: 1) }
            CodeSample()
            HStack {
                Spacer()
                LumenStatusBar {
                    Text("Ln 3, Col 9")
                    LumenStatusMenu("Syntax", selection: $syntax, options: ["HTML", "CSS", "JavaScript", "Swift"]) { $0 }
                    LumenStatusMenu("Encoding", selection: $encoding, options: ["UTF-8", "UTF-16", "ASCII"]) { $0 }
                    LumenStatusMenu("Line Endings", selection: $lineEndings, options: ["LF", "CRLF"]) { $0 }
                    LumenStatusMenu("Indentation", selection: $indentation, options: ["Tabs (4 sp)", "Spaces (2)", "Spaces (4)"]) { $0 }
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
        }
        .background(palette[.bgCanvas])
    }

    private var bottomPanel: some View {
        VStack(spacing: 0) {
            HStack {
                LumenPanelTabs(selection: $panelTab, tabs: [
                    LumenPanelTab(id: "debug", title: "Debug Console", systemImage: "ladybug.fill", hue: .hueBlue),
                    LumenPanelTab(id: "console", title: "Extension Console", systemImage: "puzzlepiece.extension.fill", hue: .hueBlue),
                    LumenPanelTab(id: "transcript", title: "Transcript", systemImage: "doc.plaintext", hue: .hueBlue),
                ])
                Spacer()
            }
            .padding(.horizontal, 10).frame(height: 34)
            .overlay(alignment: .bottom) { Rectangle().fill(palette[.borderSubtle]).frame(height: 1) }
            switch panelTab {
            case "console":
                LumenLogConsole(log) { log = [] }
            case "transcript":
                LumenEmptyState(systemImage: "doc.plaintext", title: "No transcript", message: "Language server traffic appears here.")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            default:
                LumenEmptyState(systemImage: "ladybug", title: "Not debugging", message: "No debug session is running.")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    static let sampleLog: [LumenLogEntry] = {
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        return [
            LumenLogEntry(date: start, source: "Lens Assist", message: "Lens Assist extension activated."),
            LumenLogEntry(date: start.addingTimeInterval(0.213), source: "Language Server", level: .warning, message: "Language server path is not set."),
            LumenLogEntry(date: start.addingTimeInterval(0.233), source: "Style Linter", message: "No configuration file detected."),
            LumenLogEntry(date: start.addingTimeInterval(0.316), source: "Swift", message: "Starting language server: sourcekit-lsp"),
            LumenLogEntry(date: start.addingTimeInterval(1.102), source: "Swift", level: .error, message: "sourcekit-lsp exited with status 1"),
        ]
    }()
}

/// A few lines of code with line numbers and a current line, for the workspace's editor.
private struct CodeSample: View {
    @Environment(\.lumenPalette) private var palette
    private let lines = ["<!doctype html>", "<html lang=\"en\">", "  <body>", "    <main class=\"lumen\">Hello</main>", "  </body>", "</html>"]
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                HStack(spacing: 14) {
                    Text("\(index + 1)").foregroundStyle(palette[index == 2 ? .accent : .fgTertiary]).frame(width: 28, alignment: .trailing)
                    Text(line).foregroundStyle(palette[.fgPrimary])
                    Spacer()
                }
                .font(.system(size: 13, design: .monospaced))
                .frame(height: 22)
                .background(palette[.accentSubtle].opacity(index == 2 ? 1 : 0))
            }
            Spacer()
        }
        .padding(.top, 6)
    }
}

// MARK: Split workspace (MacScope's structure)

/// The split workspace's columns. Its minimum width is their sum, and the top bar fits it.
enum SplitLayout {
    static let editorMinWidth: CGFloat = 420
    /// The top bar with its status ("Analyzing libsystem_kernel.dylib 42%") showing, past the
    /// window buttons: measured in a real window, the status first fits at 1000 (at 900 it
    /// hides, as it should, but the documented minimum promised it).
    static let topBarMinWidth: CGFloat = 1000
    static let windowMinWidth = max(LumenLayout.sidebarColumn.min + editorMinWidth + LumenLayout.inspectorColumn.min + 2,   // two dividers
                                    topBarMinWidth)
    /// The content's minimum height under the top bar (the editor keeps 360 over the debugger).
    static let contentMinHeight: CGFloat = 600
    /// The window's: the content's plus the unified band (40 pt on macOS 27), which the unified
    /// placement adds to the window's minimum itself.
    static let windowMinHeight: CGFloat = contentMinHeight + LumenLayout.unifiedTopBarHeight
}

/// A window shaped like MacScope's three-pane layout: hidden title bar, one unified top
/// bar with the window buttons inside it (app mark / binary / analyze, launch, stop + slice / analysis
/// status … panel toggles, New Tab), and an HSplitView of a navigator, an editor whose modes sit in
/// its own tab bar with a debugger deck (at most a quarter of the height; the editor keeps 360 pt)
/// and an inspector pane. No NavigationSplitView, no `.inspector`, no native toolbar.
struct SplitWorkspaceDemo: View {
    @State private var showsNavigator = true
    @State private var showsDebugger = true
    @State private var showsInspector = true
    @State private var selection: String? = "main"
    @State private var mode = CatalogEditorMode.disassembly
    @State private var activity = LumenActivity.working("Analyzing libsystem_kernel.dylib", progress: 0.42)
    @State private var hue: LumenToken = .hueIndigo
    @State private var address = ""
    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenMetrics) private var metrics

    private let symbols = [("main", "lumen.entryPoint"), ("_start", "lumen.entryPoint"), ("parse_header", "lumen.pseudocode"),
                           ("read_segment", "lumen.memoryMap"), ("sym_lookup", "lumen.crossReference")]

    var body: some View {
        HSplitView {
                if showsNavigator {
                    VStack(spacing: 0) {
                        VStack(alignment: .leading, spacing: 10) {
                            LumenSidebarHeader("Project", subtitle: "MacScope Workspace", systemImage: "square.stack.3d.up.fill", hue: .huePink)
                            LumenStatsCard([LumenStat("Targets", count: 1), LumenStat("Functions", count: symbols.count), LumenStat("Xrefs", count: 38)])
                        }
                        .padding(.horizontal, 12).padding(.top, 12)
                        LumenSourceList(symbols.map { name, glyph in LumenSourceListItem(id: name, title: name, systemImage: glyph) },
                                        selection: $selection)
                    }
                    .lumenSidebarColumn()
                }
                editor
                    .lumenBottomPanel(isPresented: $showsDebugger, contentMinHeight: 360, maxFraction: 0.25) {
                        VStack(spacing: 0) {
                            LumenPanelBar("Debugger", systemImage: "ladybug.fill", hue: .hueRed, status: "Not attached",
                                          secondary: [LumenBarAction("Breakpoints", systemImage: "lumen.breakpoint") {}],
                                          primary: LumenBarAction("Attach to Process…") {})
                            Divider()
                            LumenEmptyState(systemImage: "ladybug", title: "Not debugging", message: "No debug session is running.")
                        }
                    }
                    .lumenColumn(min: SplitLayout.editorMinWidth)
                if showsInspector {
                    LumenInspectorPane {
                        LumenInspectorHeader(selection ?? "Nothing selected", subtitle: "Function", systemImage: "lumen.pseudocode", hue: hue)
                        LumenInspectorSection("Appearance", systemImage: "paintpalette.fill", hue: .huePink) {
                            LumenHueSwatchPicker(selection: $hue)
                                .frame(width: 5 * metrics.layout.minimumHitTarget + 4 * metrics.spacing.s2, alignment: .leading)
                        }
                        LumenInspectorSection("Address Detail", systemImage: "scope", hue: .hueOrange) {
                            LumenAddressField(text: $address, hint: "Hex address, or select an instruction.") { _ in }
                        }
                    }
                }
            }
        .lumenPanelCommands(leading: $showsNavigator, bottom: $showsDebugger, trailing: $showsInspector)
        .lumenTopBar {
            SplitWorkspaceTopBar(showsNavigator: $showsNavigator, showsDebugger: $showsDebugger, showsInspector: $showsInspector,
                                 activity: $activity)
        }
        // The content's minimum: the unified placement adds the title bar band to the window's.
        .frame(minWidth: SplitLayout.windowMinWidth, minHeight: SplitLayout.contentMinHeight)
        .background(palette[.bgWindow])
    }

    private var editor: some View {
        // The editor modes live in the content pane's tab bar, not the top bar.
        VStack(spacing: 0) {
            LumenContentTabBar {
                LumenModeSwitcher(selection: $mode, options: CatalogEditorMode.allCases, style: .underline,
                                  title: \.rawValue, systemImage: \.systemImage)
                    .accessibilityLabel("Editor mode")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(["push rbp", "mov rbp, rsp", "sub rsp, 0x20", "call parse_header", "test eax, eax", "jne 0x100003f40",
                                   "leave", "ret"].enumerated()), id: \.offset) { index, line in
                        HStack(spacing: 16) {
                            Text(String(format: "0x%08X", 0x1000_3F00 + index * 4)).foregroundStyle(palette[.fgTertiary])
                            Text(line).foregroundStyle(palette[.fgPrimary])
                        }
                        .font(.body.monospaced())
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(palette[.bgCanvas])
    }
}

/// MacScope's editor modes, for the split workspace's mode switcher.
enum CatalogEditorMode: String, CaseIterable {
    case disassembly = "Disassembly", pseudocode = "Pseudocode", graph = "Graph", hex = "Hex"

    var systemImage: String {
        switch self {
        case .disassembly: "lumen.disassembly"
        case .pseudocode: "lumen.pseudocode"
        case .graph: "lumen.callGraph"
        case .hex: "number"
        }
    }

    var hue: LumenToken {
        switch self {
        case .disassembly: .hueIndigo
        case .pseudocode: .huePink
        case .graph: .hueTeal
        case .hex: .hueOrange
        }
    }
}

struct SplitWorkspaceTopBar: View {
    @Binding var showsNavigator: Bool
    @Binding var showsDebugger: Bool
    @Binding var showsInspector: Bool
    @Binding var activity: LumenActivity
    @State private var slice = "arm64e"
    @State private var showsLaunch = false

    var body: some View {
        // The toolbar: app mark / project / tasks + configuration / status … panels, New Tab.
        LumenTopBar {
            LumenWorkspaceToolbar {
                Button { showsLaunch = true } label: {
                    LumenIconTile("lumen.lens", hue: .huePink, size: 20)   // no backlight in the toolbar
                }
                .buttonStyle(.lumenPlain).lumenFocusRing().lumenIconOnlyControl("Launcher").help("Launcher")
                .lumenLaunchMenu(isPresented: $showsLaunch, items: [
                    LumenLaunchItem("Open Binary…", systemImage: "doc.fill", hue: .hueOrange, shortcut: KeyboardShortcut("o")) {},
                    LumenLaunchItem("Attach to Process…", systemImage: "ladybug.fill", hue: .hueRed) {},
                ])
            } project: {
                LumenToolbarIdentity("libsystem_kernel.dylib", subtitle: "arm64e · Mach-O dylib", systemImage: "lumen.binaryFile", hue: .hueOrange)
            } tasks: {
                LumenTaskCluster([
                    LumenTaskAction("Analyze", systemImage: "hammer.fill", hue: .hueOrange) {
                        activity = .working("Analyzing libsystem_kernel.dylib", progress: 0.1)
                    },
                    LumenTaskAction("Launch", systemImage: "play.fill", role: .start) { activity = .working("Running libsystem_kernel.dylib") },
                    LumenTaskAction("Stop", systemImage: "stop.fill", role: .stop) { activity = .idle() },
                ], activity: activity)
            } configuration: {
                LumenPopUp(selection: $slice, options: ["arm64e", "arm64", "x86_64"], title: { $0 })
            }
        } center: {
            LumenToolbarStatus(activity, width: 260)
        } trailing: {
            HStack(spacing: 2) {
                LumenPanelToggles(leading: $showsNavigator, bottom: $showsDebugger, trailing: $showsInspector, registersShortcuts: false)
                LumenNewItemButton("New Tab") {}
            }
        }
    }
}

// MARK: States & Rows

struct StatesPage: View {
    @State private var showsBanner = true
    @State private var selectedRow = "main"
    @State private var deck = "debugger"
    @State private var deckShown = true
    @State private var pane = "files"
    @AppStorage("catalog.toolArrangement") private var arrangement = ""
    @AppStorage("catalog.codeFont") private var codeFont = LumenCodeFont.standard
    @State private var progress = 0.42

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PageHeader(title: "States & Rows", summary: "What a pane says when it isn’t simply showing content, and rows that look the same in every app: selection that goes quiet in an inactive window, hover, focus and disabled.")
            LumenSectionHeader("Banner")
            if showsBanner {
                LumenBanner("The binary changed on disk since it was analyzed.", title: "Out of date", actionTitle: "Reanalyze",
                            action: {}, onDismiss: { showsBanner = false })
            } else {
                Button("Show the Banner Again") { showsBanner = true }
            }
            LumenSectionHeader("Loading and error")
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 12) { loading; failure }
                VStack(spacing: 12) { loading; failure }
            }
            // Side by side they share a top edge: no band above them, no offset between them.
            .lumenStatePlacement(.top)
            LumenSectionHeader("Rows")
            VStack(spacing: 2) {
                ForEach([("main", "0x100003F00", 12), ("parse_header", "0x100003F40", 3), ("read_segment", "0x100004010", 0)], id: \.0) { name, address, refs in
                    LumenListRow(name, detail: address, systemImage: "lumen.pseudocode", isSelected: selectedRow == name, monospaced: true) {
                        if refs > 0 { LumenCount(refs) }
                    }
                    .onTapGesture { selectedRow = name }
                }
                LumenListRow("Unavailable", systemImage: "nosign").disabled(true)
            }
            .frame(maxWidth: 380)
            .lumenCodeFont(codeFont)
            LumenCodeFontPicker(selection: $codeFont)
            LumenSectionHeader("Rearrangeable panes")
            Text("Right-click a pane to move it, hide it, show all or reset the order.").font(.callout).foregroundStyle(.lumen(.fgTertiary))
            LumenSidebarSwitcher(selection: $pane, items: [
                LumenSidebarItem(id: "files", title: "Files", systemImage: "folder"),
                LumenSidebarItem(id: "symbols", title: "Symbols", systemImage: "lumen.pseudocode"),
                LumenSidebarItem(id: "search", title: "Search", systemImage: "magnifyingglass"),
                LumenSidebarItem(id: "graph", title: "Call Graph", systemImage: "lumen.callGraph"),
            ], shortcuts: false, arrangement: $arrangement)
            .frame(maxWidth: 300)
            LumenSectionHeader("Panel decks")
            HStack(spacing: 12) {
                LumenPanelDeckControls(decks: [LumenPanelDeck(id: "debugger", title: "Debugger", systemImage: "ladybug.fill"),
                                               LumenPanelDeck(id: "shell", title: "Shell", systemImage: "terminal.fill")],
                                       selection: $deck, isPresented: $deckShown)
                Text(deckShown ? "Showing the \(deck)" : "Panel hidden").font(.callout).foregroundStyle(.lumen(.fgSecondary))
            }
            LumenSectionHeader("Empty workspace")
            LumenEmptyHero("No binary open", message: "Open a macOS executable, app bundle, framework or dylib to begin analysis.",
                           systemImage: "cpu", hue: .huePink, primary: LumenBarAction("Open Binary…") {},
                           secondary: [LumenBarAction("Open Workspace…") {}],
                           recents: [LumenRecentItem(title: "Acceptance Workspace", detail: "~/Projects/Code…acceptance1",
                                                     systemImage: "square.stack.3d.up.fill", hue: .huePink)],
                           recentsTitle: "Recent Workspaces")
                .frame(height: 420)
                .lumenCard(padding: 0)
            LumenSectionHeader("Inline welcome")
            LumenWelcomePanel(appName: "MacScope", tagline: "Open a binary to start analyzing.", markSymbol: "lumen.lens", markHue: .hueIndigo,
                              actions: [LumenWelcomeAction("Open…", subtitle: "Browse for a binary", systemImage: "folder.fill", hue: .hueBlue) {}])
                .frame(height: 300)
                .lumenCard(padding: 0)
        }
    }

    private var loading: some View {
        LumenLoadingState("Analyzing", message: "Reading symbols", progress: progress, onCancel: {}).frame(maxWidth: 320)
    }

    private var failure: some View {
        LumenErrorState("Couldn’t open the file", message: "It was moved or deleted.", recovery: "Choose it again.", onRetry: {})
            .frame(maxWidth: 320)
    }
}

